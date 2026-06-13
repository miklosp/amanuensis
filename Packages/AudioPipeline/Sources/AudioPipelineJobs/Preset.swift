import Foundation

// Shipped template that pre-fills a Job. Read from bundled presets.json at
// startup; not user-editable in this slice.
public struct Preset: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shape: JobShape
    public let baseURL: String          // empty => user must fill (generic compat)
    public let suggestedModels: [String]
    public let defaults: [String: String]
    public let docsURL: String?
    public let fieldHelp: [String: String]?      // field key -> hover tooltip text
    public let defaultOutputExt: String?         // preset's default output file extension
    public let fieldLabels: [String: String]?    // field key -> label override
    public let fieldHints: [String: String]?     // field key -> inline caption override

    public init(id: String, displayName: String, shape: JobShape,
                baseURL: String, suggestedModels: [String],
                defaults: [String: String], docsURL: String? = nil,
                fieldHelp: [String: String]? = nil,
                defaultOutputExt: String? = nil,
                fieldLabels: [String: String]? = nil,
                fieldHints: [String: String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.shape = shape
        self.baseURL = baseURL
        self.suggestedModels = suggestedModels
        self.defaults = defaults
        self.docsURL = docsURL
        self.fieldHelp = fieldHelp
        self.defaultOutputExt = defaultOutputExt
        self.fieldLabels = fieldLabels
        self.fieldHints = fieldHints
    }
}
