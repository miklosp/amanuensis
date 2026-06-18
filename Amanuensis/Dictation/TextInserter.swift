import AppKit
import CoreGraphics
import DictationCore

/// Inserts text at the cursor by placing it on the pasteboard and posting a
/// synthetic ⌘V (Post Event access — App-Sandbox-compatible). Falls back to
/// leaving text on the clipboard when access is absent or mode is clipboardOnly.
@MainActor
final class TextInserter {
    enum Outcome: Equatable { case inserted, clipboardFallback }

    static func hasPostEventAccess() -> Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }

    func insert(_ text: String, mode: InsertMode) -> Outcome {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard mode == .autoInsert, Self.hasPostEventAccess() else {
            return .clipboardFallback
        }
        postCommandV()
        if let saved {
            // Restore after the paste has been delivered to the target app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
        return .inserted
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // ANSI 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
