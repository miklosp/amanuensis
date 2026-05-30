import Foundation
import Observation

// Persistent list of Providers. JSON-on-disk in Application Support. Observable
// so the Providers UI re-renders on CRUD.
@MainActor
@Observable
public final class ProvidersStore {
    public private(set) var providers: [Provider] = []

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try load()
    }

    // Constructs a ProvidersStore at the standard app location:
    //   Application Support/<bundleID>/providers.json
    public static func standard(bundleID: String) throws -> ProvidersStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ProvidersStore(fileURL: dir.appendingPathComponent("providers.json"))
    }

    public func upsert(_ provider: Provider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    public func delete(id: UUID) {
        providers.removeAll { $0.id == id }
        save()
    }

    public func provider(id: UUID) -> Provider? {
        providers.first { $0.id == id }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        providers = try JSONDecoder().decode([Provider].self, from: data)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(providers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal for the in-memory store but worth
            // logging. Defer to OSLog from the app composition root if needed.
        }
    }
}
