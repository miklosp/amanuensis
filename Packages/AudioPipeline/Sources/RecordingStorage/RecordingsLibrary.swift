import Foundation
import Observation

// The model behind the Recordings window. Scans the recordings directory and
// parses each recording's meta.json into a list sorted newest-first.
//
// `refresh()` dispatches the scan to a background task so a library with many
// recordings doesn't stall the main thread on `Data(contentsOf:)` +
// JSONDecoder() per folder. The final assignment to `recordings` is back on
// `@MainActor`.
@MainActor
@Observable
public final class RecordingsLibrary {
    public private(set) var recordings: [RecordingItem] = []

    @ObservationIgnored private let baseURLProvider: @MainActor () -> URL

    public init(baseURLProvider: @MainActor @escaping () -> URL) {
        self.baseURLProvider = baseURLProvider
    }

    public func refresh() async {
        let baseURL = baseURLProvider()
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scan(baseURL: baseURL)
        }.value
        recordings = scanned
    }

    // Deletes a recording by moving its whole folder to the Trash (recoverable).
    public func delete(_ item: RecordingItem) async {
        try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        await refresh()
    }

    // Renames a recording by writing a display `title` into its meta.json.
    // Non-destructive: the folder (the recording's identity) is untouched.
    // A blank/whitespace title clears it, reverting the name to the folder.
    // Throws if the metadata can't be read, decoded, or written back, so the
    // caller can surface the failure instead of showing an accepted-looking
    // edit that never persisted. `refresh()` only runs after a successful write.
    public func rename(_ item: RecordingItem, to newTitle: String) async throws {
        let metadataURL = item.folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        let data = try Data(contentsOf: metadataURL)
        var meta = try Self.metadataDecoder.decode(RecordingMetadata.self, from: data)
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.title = trimmed.isEmpty ? nil : trimmed
        try meta.write(to: metadataURL)
        await refresh()
    }

    private nonisolated static let metadataDecoder = RecordingMetadata.makeDecoder()

    private nonisolated static func scan(baseURL: URL) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { RecordingItem(folderURL: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

public struct RecordingItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let folderURL: URL
    public let startedAt: Date
    public let duration: Double?
    public let sizeBytes: Int64
    public let formatSummary: String

    public nonisolated init?(folderURL: URL) {
        let metadataURL = folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: metadataURL),
              let meta = try? Self.decoder.decode(RecordingMetadata.self, from: data) else {
            return nil
        }

        id = meta.folderName
        if let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            name = title
        } else {
            name = meta.folderName
        }
        self.folderURL = folderURL
        startedAt = meta.startedAt
        duration = meta.durationSeconds

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var total: Int64 = 0
        var hasCAF = false
        var hasFLAC = false
        for file in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            switch file.pathExtension.lowercased() {
            case "caf":  hasCAF = true
            case "flac": hasFLAC = true
            default:     break
            }
        }
        sizeBytes = total
        formatSummary = [hasCAF ? "caf" : nil, hasFLAC ? "flac" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")
    }

    private nonisolated static let decoder = RecordingMetadata.makeDecoder()
}
