import AppKit
import AppLog
import AppSettings
import AudioPipelineJobs
import DictationCore
import Foundation
import Observation
import os
import RecordingCore
import RecordingStorage
import SwiftUI

// Top-level app state. Drives a pure RecorderStateMachine; performs side
// effects (permissions, file system, audio capture, FLAC conversion) outside
// the machine and feeds the results back via the machine's event methods.
//
// Public surface (status / lastError / lastFolderURL / isRecording / isBusy)
// is preserved exactly so MenuBarContent, RecordingsView, and the app entry
// point do not need edits. Those properties are computed from the machine;
// @Observable tracks reads of the `machine` storage and notifies on any
// mutation triggered by an event method.
@MainActor
@Observable
final class AppCoordinator {
    enum Status: Equatable {
        case idle
        case starting
        case recording(folderName: String)
        case stopping
    }

    var status: Status {
        switch machine.phase {
        case .idle: return .idle
        case .starting: return .starting
        case .recording(let name, _): return .recording(folderName: name)
        case .stopping: return .stopping
        }
    }

    var lastError: String? { machine.lastError }
    var lastFolderURL: URL? { machine.lastFolderURL }
    var isRecording: Bool { machine.isRecording }
    var isBusy: Bool { machine.isBusy }

    let settings: AppSettings
    let folderAccess: RecordingsFolderAccess
    let library: RecordingsLibrary
    let keychain: KeychainStore
    let presets: PresetsStore
    let jobs: JobsStore
    let providers: ProvidersStore
    let logs: LogStore
    let dictation: DictationCoordinator

    var allProviders: [Provider] { providers.providers }

    var jobActivity: String?
    var recordingActivity: String?

    private var machine = RecorderStateMachine()
    private var session: RecordingSession?
    private let conversionService = RecordingConversionService()

    // Mic-in-use cue (auto-detect a likely meeting → offer to record).
    private let micMonitor = MicActivityMonitor()
    private var micCuePolicy = MicCuePolicy()
    private let cueController = FloatingCueController()
    private var micDebounceTask: Task<Void, Never>?
    private var lastReportedCoordinatorIdle = true

    // Mic-off cue (offer to stop recording when the meeting ends).
    private let otherInputMonitor = OtherInputActivityMonitor()
    private var micOffCuePolicy = MicOffCuePolicy()
    private var micOffDebounceTask: Task<Void, Never>?
    private var lastReportedRecording = false

    init() {
        let settings = AppSettings()
        self.settings = settings
        let folderAccess = RecordingsFolderAccess(settings: settings)
        self.folderAccess = folderAccess
        self.library = RecordingsLibrary { folderAccess.effectiveURL }
        self.keychain = KeychainStore()
        do {
            self.presets = try PresetsStore.loadBundled()
        } catch {
            Self.log.error("failed to load presets: \(String(describing: error), privacy: .public)")
            self.presets = PresetsStore(presets: [])
        }
        do {
            self.jobs = try JobsStore.standard(bundleID: "work.miklos.amanuensis")
        } catch {
            Self.log.error("failed to load jobs (likely stale schema): \(String(describing: error), privacy: .public)")
            // Pre-release recovery: move the unreadable jobs.json aside to a
            // .bak so the next launch starts clean without destroying the only
            // copy — the stale file stays recoverable for inspection/migration.
            let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            if let url = support?
                .appendingPathComponent("work.miklos.amanuensis", isDirectory: true)
                .appendingPathComponent("jobs.json") {
                let backup = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url, to: backup)
            }
            // Try once more from the standard location; fall back to a temp file if even that fails.
            self.jobs = (try? JobsStore.standard(bundleID: "work.miklos.amanuensis")) ?? {
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("jobs-fallback.json")
                return (try? JobsStore(fileURL: tmp)) ?? {
                    preconditionFailure("could not initialise JobsStore even at temp path")
                }()
            }()
        }
        do {
            self.providers = try ProvidersStore.standard(bundleID: "work.miklos.amanuensis")
        } catch {
            Self.log.error("failed to load providers: \(String(describing: error), privacy: .public)")
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("providers-fallback.json")
            self.providers = (try? ProvidersStore(fileURL: tmp)) ?? {
                preconditionFailure("could not initialise ProvidersStore even at temp path")
            }()
        }
        do {
            self.logs = try LogStore.standard(bundleID: "work.miklos.amanuensis")
        } catch {
            Self.log.error("failed to init logs store: \(String(describing: error), privacy: .public)")
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("logs-fallback.json")
            self.logs = LogStore(fileURL: tmp)
        }

        self.dictation = DictationCoordinator(
            settings: settings,
            keychain: keychain,
            providerLookup: { [providers] id in providers.provider(id: id) },
            presetLookup: { [presets] id in presets.preset(id: id) },
            log: { [logs] message in logs.log(.error, message, category: .recording) }
        )

        // Start the mic-in-use cue if enabled in settings.
        _ = micCuePolicy.enabledChanged(settings.suggestRecordingWhenMicInUse)
        if settings.suggestRecordingWhenMicInUse {
            micMonitor.start { [weak self] running in self?.handleMicRunning(running) }
        }

        // Seed the mic-off cue policy. Its monitor starts only when recording
        // begins (see notifyRecordingActivity), so nothing to start here.
        _ = micOffCuePolicy.enabledChanged(settings.suggestStoppingWhenMeetingEnds)
    }

    func toggleRecording() {
        Task { @MainActor in
            if isRecording {
                await stopRecording()
            } else {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        defer { notifyRecordingActivity() }
        guard machine.start() == .requestPermissionsAndStart else { return }
        // Sync the cue policy to "busy" the moment we enter .starting — not only
        // at the exit defer — so an external mic edge during the permission
        // awaits can't arm the cue while our own recording is starting up.
        notifyRecordingActivity()

        let micGranted = await MicrophonePermission.requestIfNeeded()
        _ = machine.permissionsResolved(micGranted: micGranted)
        guard micGranted else { return }

        // System audio capture is a separate TCC grant. Without it the Core
        // Audio process tap delivers silence with no error, so request it
        // before recording. A declined grant still allows a mic-only recording.
        let systemAudioGranted = await AudioCapturePermission.requestIfNeeded()
        if !systemAudioGranted {
            Self.log.error("system audio capture not authorized — system track will be silent")
            logs.log(.warning, "System audio not authorized — system track will be silent", category: .recording)
        }

        let folder: RecordingFolder
        do {
            let store = RecordingStore(baseURL: folderAccess.effectiveURL)
            folder = try store.makeRecordingFolder(label: nil)
        } catch {
            _ = machine.sessionFailed("Couldn't create recording folder: \(error.localizedDescription)")
            return
        }

        guard machine.folderReady(name: folder.name, url: folder.url) == .startSession else { return }

        do {
            let newSession = try RecordingSession(folder: folder)
            try newSession.start()
            session = newSession
            _ = machine.sessionStarted()
            Self.log.info("recording started in \(folder.name, privacy: .public)")
            logs.log(.info, "Recording started in \(folder.name)", category: .recording)
        } catch {
            _ = machine.sessionFailed("Couldn't start recording: \(error.localizedDescription)")
            Self.log.error("start failed: \(String(describing: error), privacy: .public)")
            logs.log(.error, "Recording start failed: \(error.localizedDescription)", category: .recording)
        }
    }

    func stopRecording() async {
        defer { notifyRecordingActivity() }
        guard machine.stop() == .stopSession, let active = session else { return }

        let folder = active.folder
        let result = await active.stop()
        session = nil

        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")
        logs.log(.info, "Recording stopped — \(folder.name)", category: .recording)

        let stoppedAction = machine.sessionStopped(folderURL: folder.url)
        guard case .convertOutput = stoppedAction else { return }

        // meta.json was written synchronously inside active.stop(); the row is
        // now visible to library.refresh().
        await library.refresh()
        withAnimation { recordingActivity = "Converting recording…" }

        let keepCAF = settings.keepOriginalCAF
        let micURL = folder.micURL
        let systemURL: URL? = FileManager.default.fileExists(atPath: folder.systemURL.path)
            ? folder.systemURL : nil
        let combinedURL = folder.combinedURL
        let folderName = folder.name

        let conversionTask = await conversionService.startConversion(
            folderName: folderName,
            mic: micURL,
            system: systemURL,
            destination: combinedURL,
            keepSourcesOnSuccess: keepCAF
        )

        Task { @MainActor in
            let outcome = await conversionTask.value
            let result: Result<Void, Error>
            let flashMessage: String
            switch outcome.result {
            case .success:
                result = .success(())
                flashMessage = "Recording ready"
                self.logs.log(.info, "Recording ready — \(folderName)", category: .recording)
            case .failure(let failure):
                result = .failure(failure)
                flashMessage = "Conversion failed: \(failure.message)"
                self.logs.log(.error, "Conversion failed: \(failure.message)", category: .recording)
            }
            _ = self.machine.conversionFinished(result)
            await self.library.refresh()
            await self.flashRecordingActivity(flashMessage)
        }
    }

    func selectRecordingsFolder(_ url: URL) {
        folderAccess.select(url)
        Task { await library.refresh() }
    }

    func openRecordingsFolder() {
        let url = folderAccess.effectiveURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openLastRecordingFolder() {
        guard let url = lastFolderURL else {
            openRecordingsFolder()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func runJob(_ job: Job, on recordingFolder: URL) async -> Result<URL, Error> {
        let recordingName = recordingFolder.lastPathComponent

        guard let providerID = job.providerID,
              let provider = providers.provider(id: providerID) else {
            await self.flashActivity("Failed: '\(job.name)' — provider missing")
            logs.log(.error, "Failed: '\(job.name)' — provider missing", category: .job)
            return .failure(JobRunError.providerMissing)
        }

        guard let shape = presets.preset(id: provider.presetID)?.shape else {
            await self.flashActivity("Failed: '\(job.name)' — provider preset unknown")
            logs.log(.error, "Failed: '\(job.name)' — provider preset unknown", category: .job)
            return .failure(JobRunError.presetMissing)
        }

        if await conversionService.isConverting(folderName: recordingName) {
            withAnimation { jobActivity = "Waiting for '\(recordingName)' to finish converting…" }
            logs.log(.warning, "Waiting for '\(recordingName)' to finish converting before '\(job.name)'", category: .job)
            await conversionService.waitForConversion(folderName: recordingName)
        }

        withAnimation { jobActivity = "Running '\(job.name)' on '\(recordingName)'…" }
        logs.log(.info, "Running '\(job.name)' on '\(recordingName)'", category: .job)

        // combined.flac is the canonical input — guaranteed to exist after a
        // successful recording (mic + optional system mixed at stop).
        let target = recordingFolder.appendingPathComponent("combined.flac")
        guard FileManager.default.fileExists(atPath: target.path) else {
            await self.flashActivity("Failed: '\(job.name)' — combined.flac missing")
            logs.log(.error, "Failed: '\(job.name)' — combined.flac missing", category: .job)
            return .failure(JobRunError.combinedFlacMissing)
        }
        let runner = JobRunner(keychain: keychain)
        do {
            let out = try await runner.run(job: job, provider: provider, shape: shape, audioURL: target)
            await self.flashActivity("Done: '\(job.name)' → \(out.lastPathComponent)")
            logs.log(.info, "Done: '\(job.name)' → \(out.lastPathComponent)", category: .job)
            return .success(out)
        } catch {
            Self.log.error("job '\(job.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            await self.flashActivity("Failed: '\(job.name)' — \(error.localizedDescription)")
            logs.log(.error, "Failed: '\(job.name)' — \(error.localizedDescription)", category: .job)
            return .failure(error)
        }
    }

    // Shows a transient activity message that auto-clears after ~3 seconds.
    // A subsequent runJob call replaces this immediately (no queue).
    private func flashActivity(_ message: String) async {
        withAnimation { jobActivity = message }
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Only clear if our message is still the current one — a new run may
            // have replaced it.
            guard self?.jobActivity == snapshot else { return }
            withAnimation { self?.jobActivity = nil }
        }
    }

    // Same auto-clear pattern as flashActivity, but for the recording-conversion
    // footer line.
    private func flashRecordingActivity(_ message: String) async {
        withAnimation { recordingActivity = message }
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self?.recordingActivity == snapshot else { return }
            withAnimation { self?.recordingActivity = nil }
        }
    }

    // MARK: - Mic-in-use cue

    func setMicCueEnabled(_ enabled: Bool) {
        apply(micCuePolicy.enabledChanged(enabled))
        if enabled {
            micMonitor.start { [weak self] running in self?.handleMicRunning(running) }
        } else {
            micDebounceTask?.cancel()
            micDebounceTask = nil
            micMonitor.stop()
        }
    }

    private func handleMicRunning(_ deviceRunning: Bool) {
        // A process OTHER than us is using the mic — exclude our own PID so our
        // own dictation/recording never arms the cue. (Replaces the former
        // `dictation.phase == .idle` guard.)
        let others = deviceRunning && OtherInputActivityMonitor.othersUsingMic()
        apply(micCuePolicy.micRunningChanged(others))
    }

    // Keeps both cue policies in sync with the recorder lifecycle. Called on
    // entry to .starting and from defers on every exit path. The on-cue tracks
    // idleness; the off-cue tracks the .recording state (a separate edge —
    // .starting→.recording is not an idleness flip) and gates its per-process
    // poll monitor to the recording window.
    private func notifyRecordingActivity() {
        syncOnCueIdleness()
        syncOffCueRecordingWindow()
    }

    // On-cue: tracks the idle edge.
    private func syncOnCueIdleness() {
        let idle = (status == .idle)
        guard idle != lastReportedCoordinatorIdle else { return }
        lastReportedCoordinatorIdle = idle
        apply(micCuePolicy.recordingActivityChanged(isIdle: idle))
    }

    // Off-cue: tracks the .recording edge (distinct from idleness —
    // .starting→.recording is not an idleness flip) and gates the per-process
    // poll monitor to the recording window.
    private func syncOffCueRecordingWindow() {
        let recording: Bool
        if case .recording = status { recording = true } else { recording = false }
        guard recording != lastReportedRecording else { return }
        lastReportedRecording = recording
        applyOffCue(micOffCuePolicy.recordingChanged(isRecording: recording))
        if recording && settings.suggestStoppingWhenMeetingEnds {
            otherInputMonitor.start { [weak self] others in
                guard let self else { return }
                self.applyOffCue(self.micOffCuePolicy.othersUsingMicChanged(others))
            }
        } else {
            otherInputMonitor.stop()
        }
    }

    // Executes a MicCuePolicy.Action. May recurse (debounce → debounceElapsed).
    private func apply(_ action: MicCuePolicy.Action) {
        switch action {
        case .noop:
            break
        case .startDebounce:
            micDebounceTask?.cancel()
            micDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                self.apply(self.micCuePolicy.debounceElapsed())
            }
        case .showCue:
            showOnCue()
        case .hideCue:
            micDebounceTask?.cancel()
            micDebounceTask = nil
            cueController.hide()
        }
    }

    private func showOnCue() {
        cueController.show(onAutoDismiss: { [weak self] in
            guard let self else { return }
            self.apply(self.micCuePolicy.cueDismissed())
        }) {
            MicCueView(
                onStart: { [weak self] in
                    self?.cueController.hide()
                    self?.startFromMicCue()
                },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    self.cueController.hide()
                    self.apply(self.micCuePolicy.cueDismissed())
                }
            )
        }
    }

    private func startFromMicCue() {
        Task { @MainActor in await self.startRecording() }
    }

    func setMicOffCueEnabled(_ enabled: Bool) {
        applyOffCue(micOffCuePolicy.enabledChanged(enabled))
        if enabled {
            // Start the monitor immediately if we are already recording.
            if case .recording = status {
                otherInputMonitor.start { [weak self] others in
                    guard let self else { return }
                    self.applyOffCue(self.micOffCuePolicy.othersUsingMicChanged(others))
                }
            }
        } else {
            micOffDebounceTask?.cancel()
            micOffDebounceTask = nil
            otherInputMonitor.stop()
        }
    }

    // Executes a MicOffCuePolicy.Action. Mirrors apply(_:) for the on-cue.
    private func applyOffCue(_ action: MicOffCuePolicy.Action) {
        switch action {
        case .noop:
            break
        case .startDebounce:
            micOffDebounceTask?.cancel()
            micOffDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                self.applyOffCue(self.micOffCuePolicy.debounceElapsed())
            }
        case .showCue:
            showOffCue()
        case .hideCue:
            micOffDebounceTask?.cancel()
            micOffDebounceTask = nil
            cueController.hide()
        }
    }

    private func showOffCue() {
        cueController.show(onAutoDismiss: { [weak self] in
            guard let self else { return }
            self.applyOffCue(self.micOffCuePolicy.cueDismissed())
        }) {
            MicOffCueView(
                onStop: { [weak self] in
                    self?.cueController.hide()
                    self?.stopFromMicOffCue()
                },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    self.cueController.hide()
                    self.applyOffCue(self.micOffCuePolicy.cueDismissed())
                }
            )
        }
    }

    private func stopFromMicOffCue() {
        Task { @MainActor in await self.stopRecording() }
    }

    enum JobRunError: Error {
        case combinedFlacMissing
        case providerMissing
        case presetMissing
    }

    private static let log = Logger(subsystem: "work.miklos.amanuensis", category: "coordinator")
}
