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
        // Snapshot every flavor of every item (not just .string) so images,
        // rich text and multi-item clipboards survive the round-trip.
        let saved = Self.snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        // changeCount right after we write the dictated text. If anything else
        // mutates the pasteboard during the restore delay (the user copies
        // something), the count changes and we leave their content alone.
        let dictatedChangeCount = pb.changeCount

        guard mode == .autoInsert, Self.hasPostEventAccess() else {
            // Clipboard-fallback: deliberately leave the dictated text for the
            // user to paste manually; don't restore.
            return .clipboardFallback
        }
        postCommandV()
        // Restore the user's clipboard after the paste is delivered to the
        // target app — but only if they haven't changed it in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard pb.changeCount == dictatedChangeCount else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return .inserted
    }

    // Deep-copies the current pasteboard items. The originals are invalidated by
    // clearContents(), so each flavor's data is copied into fresh items that can
    // be written back later.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
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
