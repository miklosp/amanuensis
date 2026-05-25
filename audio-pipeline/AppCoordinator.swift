import AppKit
import AppSettings
import Foundation
import Observation
import os

// Top-level app state. Holds the active recording session (if any), surfaces
// status to the menu bar, and routes start/stop/open-folder actions through
// to the audio + storage layers.
@MainActor
@Observable
final class AppCoordinator {
    enum Status: Equatable {
        case idle
        case starting
        case recording(folderName: String)
        case stopping
    }

    private(set) var status: Status = .idle
    private(set) var lastError: String?
    private(set) var lastFolderURL: URL?

    let settings: AppSettings
    let library: RecordingsLibrary
    private var session: RecordingSession?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = RecordingsLibrary(settings: settings)
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    var isBusy: Bool {
        switch status {
        case .starting, .stopping: return true
        default: return false
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
        guard case .idle = status else { return }
        status = .starting
        lastError = nil

        let granted = await MicRecorder.requestPermissionIfNeeded()
        guard granted else {
            lastError = "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."
            status = .idle
            return
        }

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
            lastError = "Couldn't create recording folder: \(error.localizedDescription)"
            status = .idle
            return
        }

        do {
            let newSession = try RecordingSession(folder: folder)
            try newSession.start()
            session = newSession
            lastFolderURL = folder.url
            status = .recording(folderName: folder.name)
            Self.log.info("recording started in \(folder.name, privacy: .public)")
        } catch {
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            status = .idle
            Self.log.error("start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stopRecording() async {
        guard case .recording = status, let active = session else { return }
        status = .stopping
        let folder = active.folder
        let result = active.stop()
        session = nil
        status = .idle
        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")
        Task { await runOutputConversion(for: folder) }
    }

    // Runs after a recording stops. Converts mic/system tracks to FLAC per the
    // output-format setting, then refreshes the recordings list.
    private func runOutputConversion(for folder: RecordingFolder) async {
        let format = settings.outputFormat
        guard format != .caf else {
            library.refresh()
            return
        }

        let tracks: [(caf: URL, flac: URL)] = [
            (folder.micURL,
             folder.url.appending(path: "mic.flac", directoryHint: .notDirectory)),
            (folder.systemURL,
             folder.url.appending(path: "system.flac", directoryHint: .notDirectory)),
        ]

        for track in tracks {
            guard FileManager.default.fileExists(atPath: track.caf.path) else { continue }
            do {
                try await FLACExporter.export(from: track.caf, to: track.flac)
                if format == .flac {
                    try? FileManager.default.removeItem(at: track.caf)
                }
            } catch {
                lastError = "FLAC conversion failed: \(error.localizedDescription)"
                Self.log.error("FLAC export failed for \(track.caf.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        library.refresh()
    }

    func openRecordingsFolder() {
        RecordingStore(baseURL: settings.recordingsDirectory).revealInFinder()
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
