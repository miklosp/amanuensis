import Foundation

// Loads the bundled preset library once. Treated as read-only — the user
// edits Jobs, not Presets.
public struct PresetsStore: Sendable {
    public enum LoadError: Error {
        case resourceMissing
        case decodeFailed(Error)
    }

    public let all: [Preset]
    private let byID: [String: Preset]

    public init(presets: [Preset]) {
        // Sorted by display name so every preset listing (e.g. the provider
        // editor's picker) is alphabetical regardless of presets.json order.
        self.all = presets.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        self.byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
    }

    public func preset(id: String) -> Preset? {
        byID[id]
    }

    public static func loadBundled() throws -> PresetsStore {
        guard let url = Bundle.module.url(forResource: "presets", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        do {
            let data = try Data(contentsOf: url)
            let presets = try JSONDecoder().decode([Preset].self, from: data)
            return PresetsStore(presets: presets)
        } catch {
            throw LoadError.decodeFailed(error)
        }
    }
}
