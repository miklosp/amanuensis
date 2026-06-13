import Foundation
import Observation
import os

// Persistent list of Jobs. JSON-on-disk in Application Support. Observable so
// the Jobs settings panel re-renders on CRUD.
@MainActor
@Observable
public final class JobsStore {
    public private(set) var jobs: [Job] = []

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try load()
    }

    // Constructs a JobsStore at the standard app location:
    //   Application Support/<bundleID>/jobs.json
    public static func standard(bundleID: String) throws -> JobsStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try JobsStore(fileURL: dir.appendingPathComponent("jobs.json"))
    }

    public func upsert(_ job: Job) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.append(job)
        }
        save()
    }

    public func delete(id: UUID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        jobs = try JSONDecoder().decode([Job].self, from: data)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal for the in-memory store, but the
            // edit silently won't survive a relaunch — log so it's diagnosable.
            Self.log.error("jobs save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "store")
}
