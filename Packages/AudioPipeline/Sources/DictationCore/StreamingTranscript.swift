public enum ScriptKind: Equatable, Sendable, Codable {
    case partial(String)
    case final(String)
}

public struct ScriptEvent: Equatable, Sendable, Codable {
    public let delayMs: Int
    public let kind: ScriptKind
    public init(delayMs: Int, kind: ScriptKind) {
        self.delayMs = delayMs
        self.kind = kind
    }
}

public struct SimulatedTranscriptScript: Equatable, Sendable, Codable {
    public let name: String
    public let events: [ScriptEvent]
    public init(name: String, events: [ScriptEvent]) {
        self.name = name
        self.events = events
    }
}

public extension SimulatedTranscriptScript {
    /// A revising-tail utterance: "think" becomes "thought" *after* it would have
    /// been committed at a low stability window — the hard case the strategies diverge on.
    static let revisableSample = SimulatedTranscriptScript(name: "revisable", events: [
        .init(delayMs: 120, kind: .partial("I think")),
        .init(delayMs: 120, kind: .partial("I think it")),
        .init(delayMs: 120, kind: .partial("I think it is")),
        .init(delayMs: 120, kind: .partial("I thought it is")),
        .init(delayMs: 120, kind: .partial("I thought it is fine")),
        .init(delayMs: 200, kind: .final("I thought it is fine.")),
    ])

    /// Monotonic growth — each partial extends the previous; no revision.
    static let immutableSample = SimulatedTranscriptScript(name: "immutable", events: [
        .init(delayMs: 120, kind: .partial("the")),
        .init(delayMs: 120, kind: .partial("the quick")),
        .init(delayMs: 120, kind: .partial("the quick brown")),
        .init(delayMs: 120, kind: .partial("the quick brown fox")),
        .init(delayMs: 200, kind: .final("the quick brown fox.")),
    ])
}
