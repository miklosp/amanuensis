/// How a finished transcript reaches the focused app.
public enum InsertMode: String, Codable, Sendable, CaseIterable {
    case autoInsert     // synthetic ⌘V paste
    case clipboardOnly  // leave on clipboard, user pastes
}
