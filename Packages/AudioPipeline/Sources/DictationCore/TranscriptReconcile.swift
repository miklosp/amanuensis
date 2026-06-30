public struct TextDiff: Equatable, Sendable {
    public let backspaces: Int
    public let insert: String
    public init(backspaces: Int, insert: String) {
        self.backspaces = backspaces
        self.insert = insert
    }
}

/// Minimal edit from `old` to `new`: delete `backspaces` trailing characters of
/// `old`, then type `insert`. Based on the longest common (grapheme) prefix.
public func reconcile(from old: String, to new: String) -> TextDiff {
    let oc = Array(old), nc = Array(new)
    var i = 0
    while i < oc.count, i < nc.count, oc[i] == nc[i] { i += 1 }
    return TextDiff(backspaces: oc.count - i, insert: String(nc[i...]))
}

/// Result of applying one commit/hypothesis update through an insertion strategy.
public enum InsertionResult: Equatable, Sendable {
    case appended(chars: Int)
    case revised(backspaces: Int, inserted: Int)
    case revisionMiss
    case noop
}

func longestCommonPrefix(_ a: String, _ b: String) -> String {
    let ac = Array(a), bc = Array(b)
    var i = 0
    while i < ac.count, i < bc.count, ac[i] == bc[i] { i += 1 }
    return String(ac[0..<i])
}

func longestCommonPrefix(of strings: [String]) -> String {
    guard var prefix = strings.first else { return "" }
    for s in strings.dropFirst() {
        prefix = longestCommonPrefix(prefix, s)
        if prefix.isEmpty { break }
    }
    return prefix
}

/// Prefix up to and including the last whitespace, so only whole words are
/// committed. Returns "" when there is no whitespace (don't commit a partial word).
func trimToLastWordBoundary(_ s: String) -> String {
    guard let idx = s.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return "" }
    return String(s[...idx])
}
