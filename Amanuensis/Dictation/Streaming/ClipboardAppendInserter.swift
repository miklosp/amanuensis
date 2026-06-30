import DictationCore

/// Append-only: pastes newly-stabilized text via ⌘V. Cannot revise already-pasted
/// text — if committed text changes, it records a revision-miss instead.
final class ClipboardAppendInserter: InsertionStrategy {
    private var applied = ""
    private let paste: @MainActor (String) -> Void

    init(paste: @escaping @MainActor (String) -> Void = { text in
        _ = TextInserter().insert(text, mode: .autoInsert)
    }) {
        self.paste = paste
    }

    func apply(committed: String, fullHypothesis: String) -> InsertionResult {
        let diff = reconcile(from: applied, to: committed)
        if diff.backspaces > 0 { return .revisionMiss }   // can't unpaste
        guard !diff.insert.isEmpty else { return .noop }
        paste(diff.insert)
        applied = committed
        return .appended(chars: diff.insert.count)
    }

    func reset() { applied = "" }
}
