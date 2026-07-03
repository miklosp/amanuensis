import CoreGraphics
import DictationCore

/// Types the full evolving hypothesis live, backspacing and retyping the changed
/// tail when a partial revises. Never touches the clipboard.
final class KeystrokeDiffInserter: InsertionStrategy {
    private var applied = ""
    private let emit: @MainActor (Int, String) -> Void   // (backspaces, insert)

    init(emit: @escaping @MainActor (Int, String) -> Void = KeystrokeDiffInserter.postEvents) {
        self.emit = emit
    }

    func apply(committed: String, fullHypothesis: String) -> InsertionResult {
        let diff = reconcile(from: applied, to: fullHypothesis)
        if diff.backspaces == 0, diff.insert.isEmpty { return .noop }
        emit(diff.backspaces, diff.insert)
        applied = fullHypothesis
        return diff.backspaces == 0
            ? .appended(chars: diff.insert.count)
            : .revised(backspaces: diff.backspaces, inserted: diff.insert.count)
    }

    func reset() { applied = "" }

    /// Posts `backspaces` Backspace key presses, then types `insert` as a unicode string.
    static func postEvents(backspaces: Int, insert: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 51   // kVK_Delete (Backspace)
        for _ in 0..<backspaces {
            post(CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false))
        }
        guard !insert.isEmpty else { return }
        var utf16 = Array(insert.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        post(down)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        post(up)
    }

    /// Posts one synthesized key event after (1) clearing its modifier flags — so a
    /// physically-held trigger during hold-to-speak (e.g. ⌘) can't turn Backspace
    /// into ⌘⌫ (delete-to-line-start) or a letter into a shortcut — and (2) tagging
    /// it with `syntheticEventUserData` so `HotkeyTapMonitor` ignores it instead of
    /// reading our own live insertion as foreign input (which cancels the gesture
    /// and swallows the trigger release).
    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventUserData)
        event.post(tap: .cgSessionEventTap)
    }
}
