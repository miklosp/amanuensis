import Foundation

// User-defined API endpoint + credentials. Many Jobs reference one Provider.
// Shape (the wire-level protocol) is pinned by the Provider's preset, so
// switching presets is a deliberate decision the user makes on the Provider,
// not implicitly when editing a Job.
public struct Provider: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var presetID: String
    public var baseURL: String
    public var apiKeyRef: KeychainRef

    public init(id: UUID = UUID(), name: String, presetID: String,
                baseURL: String, apiKeyRef: KeychainRef) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
    }

    public static func makeDraft(presets: PresetsStore) -> Provider {
        let first = presets.all.first
        return Provider(
            name: "Untitled provider",
            presetID: first?.id ?? "",
            baseURL: first?.baseURL ?? "",
            apiKeyRef: KeychainRef(account: "")
        )
    }
}
