import Foundation
import Observation

// User preferences, persisted to UserDefaults. MainActor-isolated by the
// project's default actor isolation; observed by the Settings UI.
@Observable
final class AppSettings {
    enum OutputFormat: String, CaseIterable, Identifiable {
        case caf
        case flac
        case both

        var id: String { rawValue }

        var title: String {
            switch self {
            case .caf:  return "Keep raw (.caf)"
            case .flac: return "Convert to FLAC"
            case .both: return "Keep both"
            }
        }
    }

    var recordingsDirectory: URL {
        didSet {
            defaults.set(recordingsDirectory.path(percentEncoded: false),
                         forKey: Keys.recordingsDirectory)
        }
    }

    var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    static let defaultRecordingsDirectory: URL = URL.musicDirectory
        .appending(path: "audio-pipeline", directoryHint: .isDirectory)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let path = defaults.string(forKey: Keys.recordingsDirectory) {
            recordingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            recordingsDirectory = Self.defaultRecordingsDirectory
        }

        if let raw = defaults.string(forKey: Keys.outputFormat),
           let format = OutputFormat(rawValue: raw) {
            outputFormat = format
        } else {
            outputFormat = .caf
        }
    }

    private enum Keys {
        static let recordingsDirectory = "recordingsDirectory"
        static let outputFormat = "outputFormat"
    }
}
