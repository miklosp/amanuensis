import Foundation

// User-saved configuration for one audio→text run. References a Provider for
// endpoint/credentials/shape; carries only the per-run fields (model, prompt
// and shape-specific params, output location). Stored as JSON on disk via
// JobsStore.
public struct Job: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String                 // user label, e.g. "Swedish lesson"
    public var providerID: UUID?            // nil = unset (draft or broken)
    public var model: String                // free text; provider.preset.suggestedModels is autocomplete
    public var fields: [String: String]     // shape-specific values; keys defined by provider's preset shape
    public var outputExt: String            // "txt", "json", "srt"
    public var outputFolderPath: String?    // nil = next to recording; set = absolute path to folder

    public init(name: String, providerID: UUID?,
                model: String, fields: [String: String], outputExt: String,
                outputFolderPath: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.model = model
        self.fields = fields
        self.outputExt = outputExt
        self.outputFolderPath = outputFolderPath
    }

    public static func makeDraft() -> Job {
        Job(name: "Untitled", providerID: nil, model: "",
            fields: [:], outputExt: "txt")
    }
}
