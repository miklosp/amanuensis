/// Turns an ordered stream of trigger/foreign events into dictation gestures.
/// Tap = down→up with no foreign input and no elapsed hold. Hold = down→
/// holdElapsed→up. Any foreign key/modifier during the press cancels.
public struct ModifierGestureRecognizer: Sendable {
    public enum Gesture: Equatable, Sendable {
        case none
        case startHoldTimer
        case toggle
        case pttStart
        case pttEnd
        case cancel
    }

    public var trigger: TriggerSide
    private var tracking = false
    private var holdEngaged = false

    public init(trigger: TriggerSide) {
        self.trigger = trigger
    }

    /// The trigger ⌘ went down (no other key currently held).
    public mutating func triggerDown() -> Gesture {
        guard !tracking else { return .none }
        tracking = true
        holdEngaged = false
        return .startHoldTimer
    }

    /// The coordinator's hold timer fired while the trigger is still down.
    public mutating func holdElapsed() -> Gesture {
        guard tracking, !holdEngaged else { return .none }
        holdEngaged = true
        return .pttStart
    }

    /// The trigger ⌘ was released.
    public mutating func triggerUp() -> Gesture {
        guard tracking else { return .none }
        let result: Gesture = holdEngaged ? .pttEnd : .toggle
        tracking = false
        holdEngaged = false
        return result
    }

    /// Any non-trigger key/modifier activity — the press was part of a real
    /// shortcut, so cancel the gesture.
    public mutating func foreignInput() -> Gesture {
        guard tracking else { return .none }
        tracking = false
        holdEngaged = false
        return .cancel
    }
}
