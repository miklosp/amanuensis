import Foundation
import Testing
@testable import RecordingCore

@Suite struct MicOffCuePolicyBehavior {
    // Helper: a policy that is recording and has observed a baseline value for
    // "others using the mic" (so the next change is a genuine edge, not the
    // baseline seed).
    private func recording(enabled: Bool = true, othersBaseline: Bool) -> MicOffCuePolicy {
        var p = MicOffCuePolicy(enabled: enabled)
        _ = p.recordingChanged(isRecording: true)
        _ = p.othersUsingMicChanged(othersBaseline)   // baseline seed (no edge)
        return p
    }

    @Test func baseline_firstReport_doesNotArm() {
        var p = MicOffCuePolicy(enabled: true)
        _ = p.recordingChanged(isRecording: true)
        #expect(p.othersUsingMicChanged(true) == .none)   // baseline seed
        #expect(p.othersUsingMicChanged(false) == .startDebounce)  // first real fall
    }

    @Test func manualRecording_noOthers_neverArms() {
        var p = recording(othersBaseline: false)   // no other app on the mic
        #expect(p.othersUsingMicChanged(false) == .none)   // dedup, no edge
        #expect(p.debounceElapsed() == .none)
    }

    @Test func fallingEdge_recordingAndEnabled_startsDebounceThenShows() {
        var p = recording(othersBaseline: true)
        #expect(p.othersUsingMicChanged(false) == .startDebounce)
        #expect(p.debounceElapsed() == .showCue)
    }

    @Test func othersResume_whileShown_hides() {
        var p = recording(othersBaseline: true)
        _ = p.othersUsingMicChanged(false)
        _ = p.debounceElapsed()
        #expect(p.othersUsingMicChanged(true) == .hideCue)
    }

    @Test func reArms_afterOthersCycle() {
        var p = recording(othersBaseline: true)
        _ = p.othersUsingMicChanged(false)
        _ = p.debounceElapsed()
        #expect(p.othersUsingMicChanged(true) == .hideCue)
        #expect(p.othersUsingMicChanged(false) == .startDebounce)   // armed again
    }

    @Test func fireOncePerSession_dismissThenStaysFalse_noReshow() {
        var p = recording(othersBaseline: true)
        _ = p.othersUsingMicChanged(false)
        _ = p.debounceElapsed()
        #expect(p.cueDismissed() == .none)                 // consumed
        #expect(p.othersUsingMicChanged(false) == .none)   // dedup, no edge
        #expect(p.debounceElapsed() == .none)
        // Only a rise + fall re-arms:
        #expect(p.othersUsingMicChanged(true) == .none)    // not shown → no hide
        #expect(p.othersUsingMicChanged(false) == .startDebounce)
    }

    @Test func fallingEdge_whileNotRecording_noCue() {
        var p = MicOffCuePolicy(enabled: true)   // recording == false
        #expect(p.othersUsingMicChanged(true) == .none)    // baseline
        #expect(p.othersUsingMicChanged(false) == .none)   // consumed, not armed
        #expect(p.debounceElapsed() == .none)
    }

    @Test func recordingStops_whileShown_hides() {
        var p = recording(othersBaseline: true)
        _ = p.othersUsingMicChanged(false)
        _ = p.debounceElapsed()
        #expect(p.recordingChanged(isRecording: false) == .hideCue)
    }

    @Test func debounceAborted_whenRecordingStopsDuringDebounce() {
        var p = recording(othersBaseline: true)
        #expect(p.othersUsingMicChanged(false) == .startDebounce)
        #expect(p.recordingChanged(isRecording: false) == .none)  // armed → idle, not shown
        #expect(p.debounceElapsed() == .none)                      // late timer blocked
    }

    @Test func disabled_fallingEdge_noCue() {
        var p = recording(enabled: false, othersBaseline: true)
        #expect(p.othersUsingMicChanged(false) == .none)
        #expect(p.debounceElapsed() == .none)
    }

    @Test func disabling_whileShown_hides() {
        var p = recording(othersBaseline: true)
        _ = p.othersUsingMicChanged(false)
        _ = p.debounceElapsed()
        #expect(p.enabledChanged(false) == .hideCue)
    }

    @Test func disabling_whileArmed_returnsNoneAndSelfHeals() {
        var p = recording(othersBaseline: true)
        #expect(p.othersUsingMicChanged(false) == .startDebounce)
        #expect(p.enabledChanged(false) == .none)   // armed → idle
        #expect(p.debounceElapsed() == .none)        // late timer blocked
    }

    @Test func othersResume_whileArmed_abortsWithoutAction() {
        var p = recording(othersBaseline: true)
        #expect(p.othersUsingMicChanged(false) == .startDebounce)
        #expect(p.othersUsingMicChanged(true) == .none)   // re-arm; not shown → no hide
        #expect(p.debounceElapsed() == .none)              // late timer blocked
    }

    @Test func recordingChanged_false_reBaselines() {
        var p = recording(othersBaseline: true)
        _ = p.othersUsingMicChanged(false)        // fall
        _ = p.debounceElapsed()                   // shown
        _ = p.recordingChanged(isRecording: false)  // stop → reset + re-baseline
        _ = p.recordingChanged(isRecording: true)   // new session, gate on
        // A `false` report after restart is the new baseline, NOT a falling edge:
        #expect(p.othersUsingMicChanged(false) == .none)
        #expect(p.debounceElapsed() == .none)
    }

    @Test func enabling_doesNotRetroArm() {
        var p = recording(enabled: false, othersBaseline: true)
        #expect(p.othersUsingMicChanged(false) == .none)   // consumed while disabled
        #expect(p.enabledChanged(true) == .none)           // no edge → no arm
        #expect(p.debounceElapsed() == .none)
    }
}
