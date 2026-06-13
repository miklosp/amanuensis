import Foundation

public struct RecordingStore {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func makeRecordingFolder(label: String?, date: Date = Date()) throws -> RecordingFolder {
        let baseName = Self.folderName(date: date, label: label)
        // The timestamp resolves only to whole seconds, so two recordings
        // started in the same second would otherwise share a folder and
        // overwrite each other's tracks. Disambiguate with a `-2`, `-3`, …
        // suffix when the path is already taken.
        var name = baseName
        var attempt = 2
        var folder = baseURL.appending(path: name, directoryHint: .isDirectory)
        while FileManager.default.fileExists(atPath: folder.path) {
            name = "\(baseName)-\(attempt)"
            folder = baseURL.appending(path: name, directoryHint: .isDirectory)
            attempt += 1
        }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return RecordingFolder(url: folder, name: name, startedAt: date)
    }

    // ISO-8601 with `:` stripped to keep folder names shell-friendly.
    private static func folderName(date: Date, label: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        if let label, !label.isEmpty {
            let safe = label.replacingOccurrences(of: "/", with: "-")
            return "\(stamp)_\(safe)"
        }
        return stamp
    }
}

public struct RecordingFolder: Sendable {
    public let url: URL
    public let name: String
    public let startedAt: Date

    public init(url: URL, name: String, startedAt: Date) {
        self.url = url
        self.name = name
        self.startedAt = startedAt
    }

    public var micURL: URL { url.appending(path: "mic.caf", directoryHint: .notDirectory) }
    public var systemURL: URL { url.appending(path: "system.caf", directoryHint: .notDirectory) }
    public var combinedURL: URL { url.appending(path: "combined.flac", directoryHint: .notDirectory) }
    public var metadataURL: URL { url.appending(path: "meta.json", directoryHint: .notDirectory) }
}
