/// Which Command key is bound as the dictation trigger.
public enum TriggerSide: String, Codable, Sendable, CaseIterable {
    case leftCommand
    case rightCommand

    /// macOS virtual keycode reported by `flagsChanged` events.
    public var keyCode: Int64 {
        switch self {
        case .leftCommand:  return 55  // 0x37
        case .rightCommand: return 54  // 0x36
        }
    }
}
