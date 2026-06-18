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

    // Security-scoped bookmark for a recordings folder outside ~/Music. nil when
    // the folder is the default or under ~/Music (asset-entitlement covered).
    public var recordingsDirectoryBookmark: Data? {
        didSet {
            if let data = recordingsDirectoryBookmark {
                defaults.set(data, forKey: Keys.recordingsDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.recordingsDirectoryBookmark)
            }
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

    // When true, Amanuensis watches the default input device and shows a cue
    // offering to start recording whenever another app begins using the mic
    // (a likely meeting). Default true.
    public var suggestRecordingWhenMicInUse: Bool {
        didSet {
            defaults.set(suggestRecordingWhenMicInUse,
                         forKey: Keys.suggestRecordingWhenMicInUse)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public static let defaultRecordingsDirectory: URL = URL.musicDirectory
        .appending(path: "Amanuensis", directoryHint: .isDirectory)

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let path = defaults.string(forKey: Keys.recordingsDirectory) {
            recordingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            recordingsDirectory = Self.defaultRecordingsDirectory
        }

        recordingsDirectoryBookmark = defaults.data(forKey: Keys.recordingsDirectoryBookmark)

        if defaults.object(forKey: Keys.keepOriginalCAF) != nil {
            keepOriginalCAF = defaults.bool(forKey: Keys.keepOriginalCAF)
        } else {
            keepOriginalCAF = true
        }

        if defaults.object(forKey: Keys.suggestRecordingWhenMicInUse) != nil {
            suggestRecordingWhenMicInUse = defaults.bool(forKey: Keys.suggestRecordingWhenMicInUse)
        } else {
            suggestRecordingWhenMicInUse = true
        }
    }

    private enum Keys {
        static let recordingsDirectory = "recordingsDirectory"
        static let recordingsDirectoryBookmark = "recordingsDirectoryBookmark"
        static let keepOriginalCAF = "keepOriginalCAF"
        static let suggestRecordingWhenMicInUse = "suggestRecordingWhenMicInUse"
    }
}

extension AppSettings {
    // Pure policy: true iff `folder` is outside the Music folder and therefore
    // needs a security-scoped bookmark under App Sandbox. Paths at or under
    // ~/Music are covered directly by com.apple.security.assets.music.read-write.
    // Lexical comparison on standardized paths (no symlink resolution).
    nonisolated public static func needsSecurityScope(
        for folder: URL,
        musicDirectory: URL = .musicDirectory
    ) -> Bool {
        let f = folder.standardizedFileURL.path
        let m = musicDirectory.standardizedFileURL.path
        if f == m { return false }
        return !f.hasPrefix(m + "/")
    }
}
