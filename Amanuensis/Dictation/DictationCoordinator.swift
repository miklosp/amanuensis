import Foundation
import AppKit
import DictationCore
import LocalTranscription
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
    private let handlers: [JobShape: any AudioJobSending]
    private let log: (String) -> Void
    /// Loads the given on-device model into memory (no-op if already resident).
    private let ensureLocalModelResident: (String) async -> Void
    /// Whether the given on-device model is currently resident in memory.
    private let isLocalModelResident: (String) -> Bool

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

    // Streaming
    private var commit = CommitController(stabilityCount: 3)
    private let streamInserter = KeystrokeDiffInserter()
    private var streamingSession: (any RealtimeSTTSession)?
    private var streamContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var streamConsumeTask: Task<Void, Never>?
    private var streamSetupTask: Task<Void, Never>?
    private var isStoppingStream = false

    init(settings: AppSettings,
         keychain: any KeychainProviding,
         providerLookup: @escaping (UUID) -> Provider?,
         presetLookup: @escaping (String) -> Preset?,
         handlers: [JobShape: any AudioJobSending] = JobRunner.defaultHandlers,
         ensureLocalModelResident: @escaping (String) async -> Void = { _ in },
         isLocalModelResident: @escaping (String) -> Bool = { _ in true },
         log: @escaping (String) -> Void) {
        self.settings = settings
        self.keychain = keychain
        self.providerLookup = providerLookup
        self.presetLookup = presetLookup
        self.handlers = handlers
        self.ensureLocalModelResident = ensureLocalModelResident
        self.isLocalModelResident = isLocalModelResident
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
            if machine.phase == .idle {
                machine = DictationStateMachine(mode: currentMode())
            }
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
        case .beginStreamingCapture:
            beginStreamingCapture()
        case .endStreamingCapture:
            endStreamingCapture()
        }
        phase = machine.phase
        if phase == .idle { level = 0 }
        overlay.update(phase: phase, enabled: settings.dictation.showOverlay)
    }

    // MARK: Effects

    private func beginCapture() {
        if localDictationUnsupported {
            log("Dictation: local models require Apple Silicon")
            overlay.flash("Local dictation needs an Apple Silicon Mac")
            _ = machine.failed("local unsupported")   // returns to idle
            phase = machine.phase
            return
        }
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
        if streamingSession != nil || streamSetupTask != nil || streamContinuation != nil {
            teardownStream(delete: true)
        }
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
        if localDictationUnsupported {
            abortCapture(flash: "Local dictation needs an Apple Silicon Mac")
            return
        }
        guard let recorder, let url = captureURL,
              let inputs = resolveTranscriberInputs() else {
            abortCapture(flash: "Dictation provider unavailable")
            return
        }
        self.recorder = nil
        let transcriber = BatchTranscriber(
            job: inputs.job, provider: inputs.provider,
            shape: inputs.shape, keychain: keychain, handlers: handlers)
        let resultRef = ResultRef()
        // For on-device dictation, warm the model before transcribing so the
        // overlay shows a distinct "Loading model…" step instead of a long,
        // opaque "Transcribing…". Usually already resident (warmed on switch).
        let localModel = inputs.shape == .localTranscription ? inputs.job.model : nil
        transcribeTask = Task { [weak self] in
            _ = await recorder.stop()
            defer { self?.tempStore.delete(url) }
            if let self, let id = localModel, !self.isLocalModelResident(id) {
                self.overlay.setModelLoading(true)
                await self.ensureLocalModelResident(id)
                self.overlay.setModelLoading(false)
            }
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

    // Dictation is set to Local, but this Mac can't run on-device models. The
    // capture paths preflight on this so the user sees an Apple Silicon-specific
    // message (not the generic "no provider") and local never runs on Intel.
    private var localDictationUnsupported: Bool {
        TranscriptionSource(providerID: settings.dictation.providerID) == .local
            && !LocalModelSupport.isSupported
    }

    private func resolveTranscriberInputs() -> TranscriberInputs? {
        switch TranscriptionSource(providerID: settings.dictation.providerID) {
        case .local:
            let job = Job(
                name: "Dictation", providerID: Provider.localID,
                model: settings.dictation.model,
                fields: ["language": settings.dictation.language], outputExt: "txt")
            // Transient placeholder — LocalTranscriptionSender ignores provider/apiKey.
            return TranscriberInputs(job: job, provider: .localPlaceholder, shape: .localTranscription)
        case .provider(let id):
            guard let provider = providerLookup(id),
                  let preset = presetLookup(provider.presetID) else { return nil }
            let job = Job(
                name: "Dictation", providerID: provider.id,
                model: settings.dictation.model, fields: preset.defaults, outputExt: "txt")
            return TranscriberInputs(job: job, provider: provider, shape: preset.shape)
        case .none:
            return nil
        }
    }

    /// Streaming iff enabled in settings AND the selected provider has an adapter.
    private func currentMode() -> DictationStateMachine.Mode {
        guard settings.dictation.streamLive,
              let pid = settings.dictation.providerID,
              let provider = providerLookup(pid),
              RealtimeProviderRegistry.provider(for: provider.presetID) != nil
        else { return .batch }
        return .streaming
    }

    private struct StreamingInputs { let provider: Provider; let realtime: any RealtimeSTTProvider }

    private func resolveStreamingInputs() -> StreamingInputs? {
        guard let pid = settings.dictation.providerID,
              let provider = providerLookup(pid),
              let realtime = RealtimeProviderRegistry.provider(for: provider.presetID)
        else { return nil }
        return StreamingInputs(provider: provider, realtime: realtime)
    }

    private func beginStreamingCapture() {
        guard let inputs = resolveStreamingInputs() else {
            log("Dictation: no streaming provider configured")
            overlay.flash("Set a streaming dictation provider in Settings")
            _ = machine.failed("no streaming provider")
            phase = machine.phase
            return
        }
        isStoppingStream = false
        commit = CommitController(stabilityCount: 3)
        streamInserter.reset()
        _ = TextInserter.requestPostEventAccess()

        let url = tempStore.newCaptureURL()
        captureURL = url

        // Off-thread client callbacks → this MainActor via a single stream.
        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream()
        streamContinuation = cont
        streamConsumeTask = Task { [weak self] in
            for await event in stream { self?.handleStreamEvent(event) }
        }

        // Async connect: key fetch → session → mic. Runs on this MainActor
        // (default isolation), so the property writes are hop-free.
        streamSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let apiKey = try await self.keychain.get(account: inputs.provider.apiKeyRef.account)
                if Task.isCancelled { return }
                let session = try inputs.realtime.makeSession(
                    baseURL: inputs.provider.baseURL,
                    apiKey: apiKey,
                    language: self.settings.dictation.language,
                    onEvent: { cont.yield($0) },
                    onError: { [weak self] error in
                        Task { @MainActor in self?.handleStreamError(error) }
                    })
                session.start()
                self.streamingSession = session
                let rec = try DictationRecorder(
                    url: url,
                    onLevel: { [weak self] lvl in Task { @MainActor in self?.level = lvl } },
                    onChunk: { session.send($0) })
                try rec.start()
                self.recorder = rec
            } catch {
                self.log("Dictation streaming setup failed: \(error.localizedDescription)")
                self.overlay.flash("Dictation provider unavailable")
                self.teardownStream(delete: true)
                _ = self.machine.failed(error.localizedDescription)
                self.phase = self.machine.phase
                self.overlay.update(phase: self.machine.phase, enabled: self.settings.dictation.showOverlay)
            }
        }
    }

    private func handleStreamEvent(_ event: TranscriptEvent) {
        switch event {
        case .partial(let t): commit.update(partial: t)
        case .final(let t): commit.finalize(t)
        }
        _ = streamInserter.apply(committed: commit.committed, fullHypothesis: commit.fullHypothesis)
    }

    private func handleStreamError(_ error: Error) {
        if isStoppingStream { return }   // benign: our own finish()/cancel
        log("Dictation streaming error: \(error.localizedDescription)")
        overlay.flash("Dictation connection failed")
        teardownStream(delete: true)
        _ = machine.failed(error.localizedDescription)
        phase = machine.phase
        overlay.update(phase: machine.phase, enabled: settings.dictation.showOverlay)
    }

    /// Normal stop: flush the socket, drain trailing finals, then idle.
    private func endStreamingCapture() {
        streamSetupTask?.cancel(); streamSetupTask = nil
        isStoppingStream = true
        let session = streamingSession; streamingSession = nil
        let rec = recorder; recorder = nil
        let cont = streamContinuation; streamContinuation = nil
        let consume = streamConsumeTask; streamConsumeTask = nil
        let url = captureURL; captureURL = nil
        Task { [weak self] in
            _ = await rec?.stop()
            await session?.finish()   // trailing finals arrive via cont → handleStreamEvent
            cont?.finish()
            await consume?.value
            if let url { self?.tempStore.delete(url) }
            self?.applyAction(self?.machine.finalized() ?? .none)
        }
    }

    /// Error/abort teardown (no finalize transition; caller drives the machine).
    private func teardownStream(delete: Bool) {
        isStoppingStream = true
        streamSetupTask?.cancel(); streamSetupTask = nil
        streamConsumeTask?.cancel(); streamConsumeTask = nil
        streamContinuation?.finish(); streamContinuation = nil
        let session = streamingSession; streamingSession = nil
        let rec = recorder; recorder = nil
        let url = captureURL; captureURL = nil
        Task {
            _ = await rec?.stop()
            await session?.finish()
            if delete, let url { tempStore.delete(url) }
        }
    }
}

// MARK: - Helpers

/// Single-writer box for the transcript. Safe ONLY because `BatchTranscriber`
/// calls `onFinal` exactly once, synchronously, before `transcribe` returns —
/// the `await` is the happens-before barrier. A future streaming transcriber
/// that calls `onFinal` off-thread would need real synchronization here.
private final class ResultRef: @unchecked Sendable { nonisolated(unsafe) var value = "" }
