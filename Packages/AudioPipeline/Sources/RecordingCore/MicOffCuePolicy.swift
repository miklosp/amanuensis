// Pure decision state machine for the mic-off recording cue — the mirror of
// MicCuePolicy. Where MicCuePolicy arms on a mic *rising* edge while idle and
// offers to start recording, MicOffCuePolicy arms on the *falling* edge of
// "another app is using the mic" while *we* are recording, and offers to stop.
//
// Holds no timers and performs no IO: the driver (AppCoordinator) feeds events
// and executes the returned Action. The cue fires at most once per continuous
// "others on the mic" session: it arms only on a true→false edge of
// othersUsingMic while enabled and we are recording, and re-arms only after
// another app grabs the mic again. Stopping the recording resets the machine.
public struct MicOffCuePolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case startDebounce
        case showCue
        case hideCue
    }

    private enum Phase: Equatable {
        case idle       // waiting for a falling edge
        case armed      // edge seen; debounce in flight
        case shown      // cue visible
        case consumed   // handled this session; needs a rise to re-arm
    }

    private var phase: Phase = .idle
    private var enabled: Bool
    private var recording = false
    private var othersUsingMic: Bool?   // nil until the first report (the baseline)

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    // MARK: - Events

    public mutating func enabledChanged(_ value: Bool) -> Action {
        enabled = value
        guard !value else { return .none }
        let wasShown = (phase == .shown)
        phase = .idle
        return wasShown ? .hideCue : .none
    }

    public mutating func recordingChanged(isRecording: Bool) -> Action {
        recording = isRecording
        guard !isRecording else { return .none }  // becoming recording needs an edge
        // Recording over: reset for the next session, re-baseline, hide if shown.
        let wasShown = (phase == .shown)
        phase = .idle
        othersUsingMic = nil
        return wasShown ? .hideCue : .none
    }

    public mutating func othersUsingMicChanged(_ others: Bool) -> Action {
        let was = othersUsingMic
        othersUsingMic = others

        if others {
            // A (new) external mic session began — re-arm and retract any visible
            // cue (the meeting resumed). Mirror of MicCuePolicy's "mic fell".
            let wasShown = (phase == .shown)
            phase = .idle
            return wasShown ? .hideCue : .none
        }

        if was == nil { return .none }    // baseline seed, no edge
        if was == false { return .none }  // dedup, no edge

        // Falling edge (true → false): everyone else stopped using the mic.
        if enabled && recording && phase == .idle {
            phase = .armed
            return .startDebounce
        }
        phase = .consumed
        return .none
    }

    public mutating func debounceElapsed() -> Action {
        guard phase == .armed else { return .none }
        if enabled && recording && othersUsingMic == false {
            phase = .shown
            return .showCue
        }
        phase = .consumed
        return .none
    }

    // Returns Action for interface uniformity; always .none (dismissal needs no
    // follow-up effect — the controller self-hides).
    public mutating func cueDismissed() -> Action {
        guard phase == .shown else { return .none }
        phase = .consumed
        return .none
    }
}
