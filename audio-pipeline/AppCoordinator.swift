import AppKit
import AppSettings
import AudioPipelineJobs
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
    let library: RecordingsLibrary
    let keychain: KeychainStore
    let presets: PresetsStore
    let jobs: JobsStore

    var jobActivity: String?
    var recordingActivity: String?

    private var machine = RecorderStateMachine()
    private var session: RecordingSession?
    private let conversionService = RecordingConversionService()

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = RecordingsLibrary { settings.recordingsDirectory }
        self.keychain = KeychainStore()
        do {
            self.presets = try PresetsStore.loadBundled()
        } catch {
            Self.log.error("failed to load presets: \(String(describing: error), privacy: .public)")
            self.presets = PresetsStore(presets: [])
        }
        do {
            self.jobs = try JobsStore.standard(bundleID: "work.miklos.audio-pipeline")
        } catch {
            Self.log.error("failed to load jobs: \(String(describing: error), privacy: .public)")
            // Last-resort in-memory store at a throwaway temp path.
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("jobs-fallback.json")
            self.jobs = (try? JobsStore(fileURL: tmp)) ?? {
                preconditionFailure("could not initialise JobsStore even at temp path")
            }()
        }
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
        guard machine.start() == .requestPermissionsAndStart else { return }

        let micGranted = await MicrophonePermission.requestIfNeeded()
        _ = machine.permissionsResolved(micGranted: micGranted)
        guard micGranted else { return }

        // System audio capture is a separate TCC grant. Without it the Core
        // Audio process tap delivers silence with no error, so request it
        // before recording. A declined grant still allows a mic-only recording.
        let systemAudioGranted = await AudioCapturePermission.requestIfNeeded()
        if !systemAudioGranted {
            Self.log.error("system audio capture not authorized — system track will be silent")
        }

        let folder: RecordingFolder
        do {
            let store = RecordingStore(baseURL: settings.recordingsDirectory)
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
        } catch {
            _ = machine.sessionFailed("Couldn't start recording: \(error.localizedDescription)")
            Self.log.error("start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stopRecording() async {
        guard machine.stop() == .stopSession, let active = session else { return }

        let folder = active.folder
        let result = await active.stop()
        session = nil

        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")

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
            case .failure(let failure):
                result = .failure(failure)
                flashMessage = "Conversion failed: \(failure.message)"
            }
            _ = self.machine.conversionFinished(result)
            await self.library.refresh()
            await self.flashRecordingActivity(flashMessage)
        }
    }

    func openRecordingsFolder() {
        let url = settings.recordingsDirectory
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

        // If conversion for this recording is still in flight, wait for it
        // before checking combined.flac. Failure is fine here — the existence
        // check below will return the canonical .combinedFlacMissing.
        if await conversionService.isConverting(folderName: recordingName) {
            withAnimation { jobActivity = "Waiting for '\(recordingName)' to finish converting…" }
            await conversionService.waitForConversion(folderName: recordingName)
        }

        withAnimation { jobActivity = "Running '\(job.name)' on '\(recordingName)'…" }

        // combined.flac is the canonical input — guaranteed to exist after a
        // successful recording (mic + optional system mixed at stop).
        let target = recordingFolder.appendingPathComponent("combined.flac")
        guard FileManager.default.fileExists(atPath: target.path) else {
            await self.flashActivity("Failed: '\(job.name)' — combined.flac missing")
            return .failure(JobRunError.combinedFlacMissing)
        }
        let runner = JobRunner(keychain: keychain)
        do {
            let out = try await runner.run(job: job, audioURL: target)
            await self.flashActivity("Done: '\(job.name)' → \(out.lastPathComponent)")
            return .success(out)
        } catch {
            Self.log.error("job '\(job.name, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
            await self.flashActivity("Failed: '\(job.name)' — \(error.localizedDescription)")
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

    enum JobRunError: Error {
        case combinedFlacMissing
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "coordinator")
}
