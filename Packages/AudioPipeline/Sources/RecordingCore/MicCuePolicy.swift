// Pure decision state machine for the mic-in-use recording cue. Holds no
// timers and performs no IO: the driver (AppCoordinator) feeds events and
// executes the returned Action (start a debounce timer, show/hide the HUD).
//
// Mirrors RecorderStateMachine's pure-core pattern. The cue fires at most once
// per continuous mic session: it arms only on a false→true mic edge while the
// feature is enabled and the coordinator is idle, and re-arms only after the
// mic actually goes idle. Starting a recording, dismissing, or auto-dismiss
// all "consume" the session so we never nag mid-call or trigger off our own
// recording (which itself opens the mic).
public struct MicCuePolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case startDebounce
        case showCue
        case hideCue
    }

    private enum Phase: Equatable {
        case idle       // waiting for a rising edge
        case armed      // edge seen; debounce in flight
        case shown      // cue visible
        case consumed   // handled for this mic session; needs a fall to re-arm
    }

    private var phase: Phase = .idle
    private var enabled: Bool
    private var coordinatorIdle = true
    private var micRunning: Bool?   // nil until the first report (the baseline)

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    // MARK: - Events

    public mutating func enabledChanged(_ value: Bool) -> Action {
        enabled = value
        // Enabling never retro-arms: no mic edge has occurred, so return early.
        guard !value else { return .none }
        // Disabling: reset phase and hide any visible cue.
        let wasShown = (phase == .shown)
        phase = .idle
        return wasShown ? .hideCue : .none
    }

    public mutating func recordingActivityChanged(isIdle: Bool) -> Action {
        coordinatorIdle = isIdle
        guard !isIdle else { return .none }  // becoming idle needs an edge to arm
        let wasShown = (phase == .shown)
        if phase == .armed || phase == .shown { phase = .consumed }
        return wasShown ? .hideCue : .none
    }

    public mutating func micRunningChanged(_ running: Bool) -> Action {
        let wasRunning = micRunning
        micRunning = running

        if !running {
            let wasShown = (phase == .shown)
            phase = .idle                    // the only re-arm path
            return wasShown ? .hideCue : .none
        }

        if wasRunning == nil { return .none }   // baseline seed, no edge
        if wasRunning == true { return .none }  // dedup, no edge

        // Rising edge (false → true).
        if enabled && coordinatorIdle && phase == .idle {
            phase = .armed
            return .startDebounce
        }
        phase = .consumed                    // don't retro-arm this session
        return .none
    }

    public mutating func debounceElapsed() -> Action {
        guard phase == .armed else { return .none }
        if enabled && coordinatorIdle && micRunning == true {
            phase = .shown
            return .showCue
        }
        phase = .consumed
        return .none
    }

    // Returns Action for interface uniformity with the other events; always
    // .none (dismissal needs no follow-up effect — the controller self-hides).
    public mutating func cueDismissed() -> Action {
        guard phase == .shown else { return .none }
        phase = .consumed
        return .none
    }
}
