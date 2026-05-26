import Foundation
import Observation

// User preferences, persisted to UserDefaults. MainActor-isolated by the
// module's default actor isolation; observed by the Settings UI.
@Observable
public final class AppSettings {
    public var recordingsDirectory: URL {
        didSet {
            defaults.set(recordingsDirectory.path(percentEncoded: false),
                         forKey: Keys.recordingsDirectory)
        }
    }

    // When true, the raw mic/system .caf files are kept on disk alongside the
    // combined .flac that is always produced at recording stop. When false,
    // the .caf files are deleted after the combined export succeeds. Default
    // is true — a paranoid default that preserves the originals until the
    // user explicitly opts out.
    public var keepOriginalCAF: Bool {
        didSet { defaults.set(keepOriginalCAF, forKey: Keys.keepOriginalCAF) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public static let defaultRecordingsDirectory: URL = URL.musicDirectory
        .appending(path: "audio-pipeline", directoryHint: .isDirectory)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let path = defaults.string(forKey: Keys.recordingsDirectory) {
            recordingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            recordingsDirectory = Self.defaultRecordingsDirectory
        }

        if defaults.object(forKey: Keys.keepOriginalCAF) != nil {
            keepOriginalCAF = defaults.bool(forKey: Keys.keepOriginalCAF)
        } else {
            keepOriginalCAF = true
        }
    }

    private enum Keys {
        static let recordingsDirectory = "recordingsDirectory"
        static let keepOriginalCAF = "keepOriginalCAF"
    }
}
