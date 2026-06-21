import Foundation

/// Owns the ephemeral capture directory. Unique filenames so an in-flight
/// upload is never clobbered; `sweep()` (called on launch) reclaims orphans.
public final class DictationTempStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dictation", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    public func newCaptureURL() -> URL {
        directory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
    }

    public func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func sweep() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}
