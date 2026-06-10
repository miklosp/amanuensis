import Foundation
import Observation

// Persistent in-app activity log. JSON-on-disk in Application Support, same
// shape as JobsStore/ProvidersStore. Observable so LogsView re-renders as
// entries arrive. Keeps the most recent `limit` entries (oldest trimmed).
//
// `init(fileURL:)` is non-throwing: load() is best-effort, so a missing or
// corrupt file yields an empty log rather than a launch failure. The throwing
// surface is `standard(bundleID:)`, which can fail only on directory creation.
@MainActor
@Observable
public final class LogStore {
    public private(set) var entries: [LogEntry] = []  // oldest -> newest

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let limit: Int

    public init(fileURL: URL, limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = limit
        load()
    }

    // Constructs a LogStore at the standard app location:
    //   Application Support/<bundleID>/logs.json
    public static func standard(bundleID: String) throws -> LogStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LogStore(fileURL: dir.appendingPathComponent("logs.json"))
    }

    public func log(_ level: LogEntry.Level, _ message: String, category: LogEntry.Category) {
        entries.append(LogEntry(date: Date(), level: level, category: category, message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    // Best-effort: missing file -> empty; unreadable/corrupt -> empty.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else {
            return  // entries stays at its initial []
        }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
