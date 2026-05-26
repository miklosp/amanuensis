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
        self.all = presets
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
