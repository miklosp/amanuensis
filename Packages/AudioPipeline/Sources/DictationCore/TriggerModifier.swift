/// A modifier key bound as the dictation trigger.
///
/// Replaces the original `TriggerSide`, which only chose left vs right ⌘; the
/// meaning is now "which modifier key". The `leftCommand`/`rightCommand` raw
/// values are kept identical so `DictationSettings` saved before the rename
/// decode unchanged (no migration). Default trigger stays `.rightCommand`.
///
/// Right Control is omitted (no Apple keyboard has it) and Caps Lock is omitted
/// (it reports a latched state, not a press/release, so the sandbox-safe
/// listen-only tap can't do hold-to-talk). Every listed key is momentary.
///
/// Case order follows the physical Apple-keyboard layout (left ⇧, Fn, the
/// bottom-left ⌃⌥⌘ cluster, then the bottom-right ⌘⌥ cluster, then right ⇧);
/// `allCases` drives the Settings picker, so this order is what the user sees.
public enum TriggerModifier: String, Codable, Sendable, CaseIterable {
    case leftShift
    case function
    case leftControl
    case leftOption
    case leftCommand
    case rightCommand
    case rightOption
    case rightShift

    /// macOS virtual keycode reported in `flagsChanged` events.
    public var keyCode: Int64 {
        switch self {
        case .leftShift:    return 56  // 0x38
        case .function:     return 63  // 0x3F
        case .leftControl:  return 59  // 0x3B
        case .leftOption:   return 58  // 0x3A
        case .leftCommand:  return 55  // 0x37
        case .rightCommand: return 54  // 0x36
        case .rightOption:  return 61  // 0x3D
        case .rightShift:   return 60  // 0x3C
        }
    }

    /// Bit in `CGEvent.flags.rawValue` set while this key is down.
    ///
    /// The sided keys use the device-dependent IOKit `NX_DEVICE*KEYMASK` bits,
    /// so left and right are distinguishable; Fn uses `CGEventFlags.maskSecondaryFn`.
    /// Literals keep this pure module free of a CoreGraphics import;
    /// `HotkeyTapMonitor` reads the live flags.
    public var deviceFlagBit: UInt64 {
        switch self {
        case .leftShift:    return 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
        case .function:     return 0x0080_0000  // CGEventFlags.maskSecondaryFn
        case .leftControl:  return 0x0000_0001  // NX_DEVICELCTLKEYMASK
        case .leftOption:   return 0x0000_0020  // NX_DEVICELALTKEYMASK
        case .leftCommand:  return 0x0000_0008  // NX_DEVICELCMDKEYMASK
        case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .rightOption:  return 0x0000_0040  // NX_DEVICERALTKEYMASK
        case .rightShift:   return 0x0000_0004  // NX_DEVICERSHIFTKEYMASK
        }
    }

    /// Label for the Settings picker.
    public var displayName: String {
        switch self {
        case .leftShift:    return "Left ⇧"
        case .function:     return "Fn 🌐"
        case .leftControl:  return "Left ⌃"
        case .leftOption:   return "Left ⌥"
        case .leftCommand:  return "Left ⌘"
        case .rightCommand: return "Right ⌘"
        case .rightOption:  return "Right ⌥"
        case .rightShift:   return "Right ⇧"
        }
    }
}
