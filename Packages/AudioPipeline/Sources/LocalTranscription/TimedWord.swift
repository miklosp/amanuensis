public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct DiarizedSegment: Sendable, Equatable {
    public let speakerId: String
    public let start: Double
    public let end: Double
    public init(speakerId: String, start: Double, end: Double) {
        self.speakerId = speakerId; self.start = start; self.end = end
    }
}
