import Foundation
import AppKit
import DictationCore
import RecordingCore
import AudioPipelineJobs
import AppSettings

/// Wires hotkey gestures → dictation state machine → capture/transcribe/insert.
/// Hung off AppCoordinator; mirrors the mic-cue apply(_:) pattern.
@MainActor
@Observable
final class DictationCoordinator {
    private(set) var phase: DictationStateMachine.Phase = .idle
    private(set) var level: Float = 0

    private let settings: AppSettings
    private let keychain: any KeychainProviding
    private let providerLookup: (UUID) -> Provider?
    private let presetLookup: (String) -> Preset?
    private let log: (String) -> Void

    private var recognizer: ModifierGestureRecognizer
    private var machine = DictationStateMachine()
    private let inserter = TextInserter()
    private let tempStore = DictationTempStore()
    private let overlay = DictationOverlayController()
    private var monitor: HotkeyTapMonitor?

    private var recorder: DictationRecorder?
    private var captureURL: URL?
    private var holdTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    init(settings: AppSettings,
         keychain: any KeychainProviding,
         providerLookup: @escaping (UUID) -> Provider?,
         presetLookup: @escaping (String) -> Preset?,
         log: @escaping (String) -> Void) {
        self.settings = settings
        self.keychain = keychain
        self.providerLookup = providerLookup
        self.presetLookup = presetLookup
        self.log = log
        self.recognizer = ModifierGestureRecognizer(trigger: settings.dictation.trigger)
        tempStore.sweep()                       // reclaim crash orphans on launch
        if settings.dictation.enabled { startMonitor() }
    }

    // MARK: Settings

    /// Called from Settings when `enabled` or `trigger` changes.
    func settingsChanged() {
        recognizer.trigger = settings.dictation.trigger
        monitor?.setTrigger(settings.dictation.trigger)
        if settings.dictation.enabled {
            startMonitor()
        } else {
            stopMonitor()
            abortCapture(flash: nil)
        }
    }

    private func startMonitor() {
        if monitor == nil {
            monitor = HotkeyTapMonitor(trigger: settings.dictation.trigger) { [weak self] event in
                self?.handle(event)
            }
        }
        monitor?.start()
    }

    private func stopMonitor() {
        holdTask?.cancel(); holdTask = nil
        monitor?.stop()
    }

    // MARK: Event pipeline

    private func handle(_ event: HotkeyTapMonitor.Event) {
        switch event {
        case .triggerDown: applyGesture(recognizer.triggerDown())
        case .triggerUp:   applyGesture(recognizer.triggerUp())
        case .foreignInput: applyGesture(recognizer.foreignInput())
        }
    }

    private func applyGesture(_ gesture: ModifierGestureRecognizer.Gesture) {
        switch gesture {
        case .none:
            break
        case .startHoldTimer:
            holdTask?.cancel()
            let ms = settings.dictation.holdThresholdMs
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                guard let self, !Task.isCancelled else { return }
                self.applyGesture(self.recognizer.holdElapsed())
            }
        case .toggle, .pttStart:
            applyAction(machine.startOrToggle())
        case .pttEnd:
            applyAction(machine.release())
        case .cancel:
            holdTask?.cancel(); holdTask = nil
        }
    }

    private func applyAction(_ action: DictationStateMachine.Action) {
        switch action {
        case .none:
            break
        case .beginCapture:
            beginCapture()
        case .endCaptureAndTranscribe:
            endCaptureAndTranscribe()
        case .insert(let text):
            let outcome = inserter.insert(text, mode: settings.dictation.insertMode)
            if outcome == .clipboardFallback {
                overlay.flash("Copied — press ⌘V")
            }
            applyAction(machine.inserted())
        case .showError(let message):
            log("Dictation failed: \(message)")
            overlay.flash("Dictation failed")
        case .showEmpty:
            overlay.flash("Nothing heard")
        }
        phase = machine.phase
        if phase == .idle { level = 0 }
        overlay.update(phase: phase, enabled: settings.dictation.showOverlay)
    }

    // MARK: Effects

    private func beginCapture() {
        guard resolveTranscriberInputs() != nil else {
            log("Dictation: no provider configured")
            overlay.flash("Set a dictation provider in Settings")
            _ = machine.failed("no provider")   // returns to idle
            phase = machine.phase
            return
        }
        let url = tempStore.newCaptureURL()
        captureURL = url
        do {
            let rec = try DictationRecorder(url: url) { [weak self] lvl in
                let weakSelf = self
                Task { @MainActor in weakSelf?.level = lvl }
            }
            try rec.start()
            recorder = rec
        } catch {
            // DictationRecorder.init already created the WAV on disk; remove it
            // and clear captureURL so a failed start leaves no orphan temp file.
            tempStore.delete(url)
            captureURL = nil
            log("Dictation capture failed: \(error.localizedDescription)")
            overlay.flash("Mic unavailable")
            _ = machine.failed(error.localizedDescription)
            phase = machine.phase
        }
    }

    /// Tear down any in-flight capture/transcription and return to idle. Used
    /// when a capture must be abandoned out-of-band (provider unavailable,
    /// dictation disabled). `flash` shows a user message; nil aborts silently.
    private func abortCapture(flash: String?) {
        holdTask?.cancel(); holdTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        if let rec = recorder {
            recorder = nil
            let doomed = captureURL
            captureURL = nil
            // Delete only AFTER stop() finishes flushing/finalizing the WAV —
            // deleting while the writer is still draining races the file write.
            Task {
                _ = await rec.stop()
                if let doomed { tempStore.delete(doomed) }
            }
        } else if let url = captureURL {
            tempStore.delete(url)
            captureURL = nil
        }
        machine.reset()
        level = 0
        phase = machine.phase
        if let flash {
            overlay.flash(flash)
        } else {
            overlay.update(phase: phase, enabled: settings.dictation.showOverlay)
        }
    }

    private func endCaptureAndTranscribe() {
        guard let recorder, let url = captureURL,
              let inputs = resolveTranscriberInputs() else {
            abortCapture(flash: "Dictation provider unavailable")
            return
        }
        self.recorder = nil
        let transcriber = BatchTranscriber(
            job: inputs.job, provider: inputs.provider,
            shape: inputs.shape, keychain: keychain)
        let resultRef = ResultRef()
        transcribeTask = Task { [weak self] in
            _ = await recorder.stop()
            defer { self?.tempStore.delete(url) }
            do {
                try await transcriber.transcribe(
                    audioFile: url, onPartial: { _ in }, onFinal: { resultRef.value = $0 })
                self?.applyAction(self?.machine.transcriptReady(resultRef.value) ?? .none)
            } catch {
                self?.applyAction(self?.machine.failed(error.localizedDescription) ?? .none)
            }
        }
    }

    private struct TranscriberInputs { let job: Job; let provider: Provider; let shape: JobShape }

    private func resolveTranscriberInputs() -> TranscriberInputs? {
        guard let pid = settings.dictation.providerID,
              let provider = providerLookup(pid),
              let preset = presetLookup(provider.presetID) else { return nil }
        let job = Job(
            name: "Dictation", providerID: provider.id,
            model: settings.dictation.model, fields: preset.defaults, outputExt: "txt")
        return TranscriberInputs(job: job, provider: provider, shape: preset.shape)
    }
}

// MARK: - Helpers

/// Single-writer box for the transcript. Safe ONLY because `BatchTranscriber`
/// calls `onFinal` exactly once, synchronously, before `transcribe` returns —
/// the `await` is the happens-before barrier. A future streaming transcriber
/// that calls `onFinal` off-thread would need real synchronization here.
private final class ResultRef: @unchecked Sendable { nonisolated(unsafe) var value = "" }
