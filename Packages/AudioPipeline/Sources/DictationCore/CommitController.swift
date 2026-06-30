/// Stabilizes a stream of revising partials into a growing committed prefix plus a
/// volatile tail. Pure and synchronous; the replay timeline lives in the source.
public struct CommitController: Sendable {
    public let stabilityCount: Int
    public private(set) var committed = ""
    public private(set) var volatileTail = ""
    public private(set) var fullHypothesis = ""

    private var finalizedText = ""
    private var recentPartials: [String] = []
    private var segmentCommitted = ""

    public init(stabilityCount: Int = 2) {
        self.stabilityCount = max(1, stabilityCount)
    }

    public mutating func update(partial: String) {
        recentPartials.append(partial)
        if recentPartials.count > stabilityCount { recentPartials.removeFirst() }

        let stable = recentPartials.count == stabilityCount
            ? longestCommonPrefix(of: recentPartials)
            : segmentCommitted
        // `stable` is always a prefix of `partial` (it includes `partial` in its LCP
        // once the window is full; before that, segmentCommitted is still "").
        segmentCommitted = trimToLastWordBoundary(stable)

        committed = finalizedText + segmentCommitted
        volatileTail = String(partial.dropFirst(segmentCommitted.count))
        fullHypothesis = finalizedText + partial
    }

    public mutating func finalize(_ text: String) {
        finalizedText += text
        committed = finalizedText
        fullHypothesis = finalizedText
        volatileTail = ""
        segmentCommitted = ""
        recentPartials = []
    }
}
