import Foundation
import Testing
@testable import RecordingCore

@Suite struct MicCuePolicyBehavior {
    // Helper: seed a policy that has already observed mic=false (so the next
    // `true` is a genuine rising edge, not the baseline).
    private func seededFalse(enabled: Bool = true) -> MicCuePolicy {
        var p = MicCuePolicy(enabled: enabled)
        _ = p.micRunningChanged(false)   // baseline: micRunning=false, phase=idle
        return p
    }

    @Test func baseline_firstReportTrue_doesNotArm() {
        var p = MicCuePolicy(enabled: true)
        #expect(p.micRunningChanged(true) == .none)        // baseline seed, no edge
        #expect(p.debounceElapsed() == .none)              // nothing was armed
    }

    @Test func risingEdge_enabledAndIdle_startsDebounceThenShows() {
        var p = seededFalse()
        #expect(p.micRunningChanged(true) == .startDebounce)
        #expect(p.debounceElapsed() == .showCue)
    }

    @Test func micFalls_whileShown_hides() {
        var p = seededFalse()
        _ = p.micRunningChanged(true)
        _ = p.debounceElapsed()
        #expect(p.micRunningChanged(false) == .hideCue)
    }

    @Test func reArms_afterMicCycles() {
        var p = seededFalse()
        _ = p.micRunningChanged(true)
        _ = p.debounceElapsed()
        #expect(p.micRunningChanged(false) == .hideCue)
        #expect(p.micRunningChanged(true) == .startDebounce)   // armed again
    }

    @Test func fireOncePerSession_dismissThenStaysTrue_noReshow() {
        var p = seededFalse()
        _ = p.micRunningChanged(true)
        _ = p.debounceElapsed()
        #expect(p.cueDismissed() == .none)                 // consumed
        #expect(p.micRunningChanged(true) == .none)        // still true, no new edge
        #expect(p.debounceElapsed() == .none)
        // Only a fall + rise re-arms:
        #expect(p.micRunningChanged(false) == .none)       // not shown → no hide
        #expect(p.micRunningChanged(true) == .startDebounce)
    }

    @Test func risingEdge_whileBusy_noCue() {
        var p = seededFalse()
        #expect(p.recordingActivityChanged(isIdle: false) == .none)
        #expect(p.micRunningChanged(true) == .none)        // consumed, not armed
        #expect(p.debounceElapsed() == .none)
    }

    @Test func busyTransition_whileShown_hides() {
        var p = seededFalse()
        _ = p.micRunningChanged(true)
        _ = p.debounceElapsed()
        #expect(p.recordingActivityChanged(isIdle: false) == .hideCue)
    }

    @Test func debounceAborted_whenBusyDuringDebounce() {
        var p = seededFalse()
        #expect(p.micRunningChanged(true) == .startDebounce)
        #expect(p.recordingActivityChanged(isIdle: false) == .none)  // armed → consumed
        #expect(p.debounceElapsed() == .none)              // no show
    }

    @Test func disabled_risingEdge_noCue() {
        var p = seededFalse(enabled: false)
        #expect(p.micRunningChanged(true) == .none)
        #expect(p.debounceElapsed() == .none)
    }

    @Test func disabling_whileShown_hides() {
        var p = seededFalse()
        _ = p.micRunningChanged(true)
        _ = p.debounceElapsed()
        #expect(p.enabledChanged(false) == .hideCue)
    }

    @Test func enabling_doesNotRetroArmRunningMic() {
        var p = seededFalse(enabled: false)
        #expect(p.micRunningChanged(true) == .none)        // consumed while disabled
        #expect(p.enabledChanged(true) == .none)           // no edge → no arm
        #expect(p.debounceElapsed() == .none)
    }

    @Test func micFalls_whileArmed_abortsWithoutAction() {
        var p = seededFalse()
        #expect(p.micRunningChanged(true) == .startDebounce)
        #expect(p.micRunningChanged(false) == .none)   // abort mid-debounce; not shown → no hide
        #expect(p.debounceElapsed() == .none)           // late timer fires; guard blocks it
    }

    @Test func disabling_whileArmed_returnsNoneAndSelfHeals() {
        var p = seededFalse()
        #expect(p.micRunningChanged(true) == .startDebounce)
        #expect(p.enabledChanged(false) == .none)   // armed → idle; no visible cue to hide
        #expect(p.debounceElapsed() == .none)        // late timer fires; guard blocks the show
    }
}
