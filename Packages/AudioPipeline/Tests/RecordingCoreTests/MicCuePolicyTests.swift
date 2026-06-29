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
        #expect(p.micRunningChanged(true) == .noop)        // baseline seed, no edge
        #expect(p.debounceElapsed() == .noop)              // nothing was armed
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
        #expect(p.cueDismissed() == .noop)                 // consumed
        #expect(p.micRunningChanged(true) == .noop)        // still true, no new edge
        #expect(p.debounceElapsed() == .noop)
        // Only a fall + rise re-arms:
        #expect(p.micRunningChanged(false) == .noop)       // not shown → no hide
        #expect(p.micRunningChanged(true) == .startDebounce)
    }

    @Test func risingEdge_whileBusy_noCue() {
        var p = seededFalse()
        #expect(p.recordingActivityChanged(isIdle: false) == .noop)
        #expect(p.micRunningChanged(true) == .noop)        // consumed, not armed
        #expect(p.debounceElapsed() == .noop)
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
        #expect(p.recordingActivityChanged(isIdle: false) == .noop)  // armed → consumed
        #expect(p.debounceElapsed() == .noop)              // no show
    }

    @Test func disabled_risingEdge_noCue() {
        var p = seededFalse(enabled: false)
        #expect(p.micRunningChanged(true) == .noop)
        #expect(p.debounceElapsed() == .noop)
    }

    @Test func disabling_whileShown_hides() {
        var p = seededFalse()
        _ = p.micRunningChanged(true)
        _ = p.debounceElapsed()
        #expect(p.enabledChanged(false) == .hideCue)
    }

    @Test func enabling_doesNotRetroArmRunningMic() {
        var p = seededFalse(enabled: false)
        #expect(p.micRunningChanged(true) == .noop)        // consumed while disabled
        #expect(p.enabledChanged(true) == .noop)           // no edge → no arm
        #expect(p.debounceElapsed() == .noop)
    }

    @Test func micFalls_whileArmed_abortsWithoutAction() {
        var p = seededFalse()
        #expect(p.micRunningChanged(true) == .startDebounce)
        #expect(p.micRunningChanged(false) == .noop)   // abort mid-debounce; not shown → no hide
        #expect(p.debounceElapsed() == .noop)           // late timer fires; guard blocks it
    }

    @Test func disabling_whileArmed_returnsNoneAndSelfHeals() {
        var p = seededFalse()
        #expect(p.micRunningChanged(true) == .startDebounce)
        #expect(p.enabledChanged(false) == .noop)   // armed → idle; no visible cue to hide
        #expect(p.debounceElapsed() == .noop)        // late timer fires; guard blocks the show
    }
}
