import DictationCore

/// Strategy for reflecting transcript state into the frontmost app.
/// `committed` is stabilized text; `fullHypothesis` is the full evolving text.
protocol InsertionStrategy: AnyObject {
    func apply(committed: String, fullHypothesis: String) -> InsertionResult
    func reset()
}
