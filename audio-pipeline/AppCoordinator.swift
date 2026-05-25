import AppKit
import AppSettings
import Foundation
import Observation
import os
import RecordingCore
import RecordingStorage

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

    private var machine = RecorderStateMachine()
    private var session: RecordingSession?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = RecordingsLibrary { settings.recordingsDirectory }
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
        let result = active.stop()
        session = nil

        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")

        let stoppedAction = machine.sessionStopped(folderURL: folder.url)
        if case .convertOutput = stoppedAction {
            Task { @MainActor in
                let conversionResult = await self.runConversion(for: folder)
                _ = self.machine.conversionFinished(conversionResult)
                self.library.refresh()
            }
        }
    }

    // Runs after a recording stops. Converts mic/system tracks to FLAC per the
    // output-format setting. Returns one Result — on any track failure, the
    // first error is surfaced (spec §7 'Faithful simplification').
    private func runConversion(for folder: RecordingFolder) async -> Result<Void, Error> {
        let tasks = OutputConversionPlanner.plan(folder: folder, format: settings.outputFormat)

        var firstFailure: Error?
        for task in tasks {
            do {
                try await FLACExporter.export(from: task.source, to: task.destination)
                if task.deleteSourceAfterExport {
                    try? FileManager.default.removeItem(at: task.source)
                }
            } catch {
                if firstFailure == nil { firstFailure = error }
                Self.log.error("FLAC export failed for \(task.source.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if let firstFailure { return .failure(firstFailure) }
        return .success(())
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

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "coordinator")
}
