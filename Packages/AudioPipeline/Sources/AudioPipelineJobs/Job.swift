import Foundation

// User-saved configuration for one audio→text run. Many Jobs may share a
// presetID. Stored as JSON on disk via JobsStore.
public struct Job: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String                 // user label, e.g. "Swedish lesson"
    public var presetID: String             // links back to Preset
    public var baseURL: String              // may diverge from preset (self-hosted)
    public var model: String                // free text; preset.suggestedModels is just autocomplete
    public var apiKeyRef: KeychainRef
    public var fields: [String: String]     // shape-specific values
    public var outputExt: String            // "txt", "json", "srt"

    public init(id: UUID = UUID(), name: String, presetID: String,
                baseURL: String, model: String, apiKeyRef: KeychainRef,
                fields: [String: String], outputExt: String) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.baseURL = baseURL
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.fields = fields
        self.outputExt = outputExt
    }
}
