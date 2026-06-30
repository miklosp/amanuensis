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
    // Security-scoped bookmark for outputFolderPath when it's outside ~/Music
    // (App Sandbox needs it to write there across launches). nil = folder is the
    // recording's own folder or under ~/Music (asset-entitlement covered), or a
    // legacy job saved before bookmarks existed (the run path re-prompts once).
    public var outputFolderBookmark: Data?

    public init(name: String, providerID: UUID?,
                model: String, fields: [String: String], outputExt: String,
                outputFolderPath: String? = nil, outputFolderBookmark: Data? = nil,
                id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.model = model
        self.fields = fields
        self.outputExt = outputExt
        self.outputFolderPath = outputFolderPath
        self.outputFolderBookmark = outputFolderBookmark
    }

    public static func makeDraft() -> Job {
        Job(name: "Untitled", providerID: nil, model: "",
            fields: [:], outputExt: "txt")
    }
}
