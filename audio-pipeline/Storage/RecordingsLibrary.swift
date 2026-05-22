import Foundation
import Observation

// The model behind the Recordings window. Scans the recordings directory and
// parses each recording's meta.json into a list sorted newest-first.
@Observable
final class RecordingsLibrary {
    private(set) var recordings: [RecordingItem] = []

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func refresh() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: settings.recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            recordings = []
            return
        }

        recordings = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { RecordingItem(folderURL: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // Deletes a recording by moving its whole folder to the Trash (recoverable).
    func delete(_ item: RecordingItem) {
        try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        refresh()
    }
}

struct RecordingItem: Identifiable {
    let id: String
    let name: String
    let folderURL: URL
    let startedAt: Date
    let duration: Double?
    let sizeBytes: Int64
    let formatSummary: String

    init?(folderURL: URL) {
        let metadataURL = folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: metadataURL),
              let meta = try? Self.decoder.decode(RecordingMetadata.self, from: data) else {
            return nil
        }

        id = meta.folderName
        name = meta.folderName
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

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
