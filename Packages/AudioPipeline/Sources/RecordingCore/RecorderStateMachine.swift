import Foundation

// Pure value-type lifecycle state machine for a recording session. Holds the
// current phase plus error/folder side-fields; transition methods mutate state
// and return a typed Action the driver executes.
//
// The machine does not know about Core Audio, AppSettings, or storage —
// URLs and folder names are opaque payloads carried by events. The driver
// constructs RecordingFolder/RecordingSession and feeds results back via the
// event methods below.
public struct RecorderStateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording(folderName: String, folderURL: URL)
        case stopping
    }

    public enum Action: Equatable, Sendable {
        case none
        case requestPermissionsAndStart
        case startSession
        case stopSession
        case convertOutput(folderURL: URL)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastError: String?
    public private(set) var lastFolderURL: URL?

    // Folder info gathered during .starting before sessionStarted() promotes
    // the phase to .recording. Not exposed — interim state only.
    private var pendingFolder: PendingFolder?

    private struct PendingFolder: Sendable {
        let name: String
        let url: URL
    }

    public init() {}

    // MARK: - Events

    public mutating func start() -> Action {
        guard case .idle = phase else { return .none }
        lastError = nil
        phase = .starting
        pendingFolder = nil
        return .requestPermissionsAndStart
    }

    public mutating func permissionsResolved(micGranted: Bool) -> Action {
        guard case .starting = phase else { return .none }
        if micGranted { return .none }
        lastError = "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."
        phase = .idle
        return .none
    }

    public mutating func folderReady(name: String, url: URL) -> Action {
        guard case .starting = phase else { return .none }
        pendingFolder = PendingFolder(name: name, url: url)
        return .startSession
    }

    public mutating func sessionStarted() -> Action {
        guard case .starting = phase, let folder = pendingFolder else { return .none }
        phase = .recording(folderName: folder.name, folderURL: folder.url)
        pendingFolder = nil
        return .none
    }

    public mutating func sessionFailed(_ error: String) -> Action {
        guard case .starting = phase else { return .none }
        lastError = error
        phase = .idle
        pendingFolder = nil
        return .none
    }

    public mutating func stop() -> Action {
        guard case .recording = phase else { return .none }
        phase = .stopping
        return .stopSession
    }

    public mutating func sessionStopped(folderURL: URL) -> Action {
        guard case .stopping = phase else { return .none }
        lastFolderURL = folderURL
        phase = .idle
        return .convertOutput(folderURL: folderURL)
    }

    // Conversion runs after the phase has returned to .idle (see spec §7), so
    // it doesn't move the lifecycle phase. Only a failure surfaces an error.
    public mutating func conversionFinished(_ result: Result<Void, Error>) -> Action {
        if case .failure(let error) = result {
            lastError = "FLAC conversion failed: \(error.localizedDescription)"
        }
        return .none
    }

    // MARK: - Query properties (used by the menu bar UI)

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    public var isBusy: Bool {
        switch phase {
        case .starting, .stopping: return true
        case .idle, .recording: return false
        }
    }

    public var statusText: String {
        switch phase {
        case .idle: return "Idle"
        case .starting: return "Starting…"
        case .recording(let name, _): return "Recording: \(name)"
        case .stopping: return "Stopping…"
        }
    }
}
