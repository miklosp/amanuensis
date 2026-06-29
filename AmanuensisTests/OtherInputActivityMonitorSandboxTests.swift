import XCTest
import CoreAudio
import RecordingCore

// Verifies the per-process Core Audio API the mic cues depend on is reachable
// from inside the codesigned, sandboxed app host — i.e. that App Sandbox does
// not block `kAudioHardwarePropertyProcessObjectList` with no extra entitlement.
//
// This is the runtime risk flagged in the mic-off-cue design's "Risk note":
// after the mic-ON cue's dictation guard was removed, BOTH cues depend on this
// API, so a sandbox block would silently disable them (no true→false edge to
// fire on). Runs in AmanuensisTests because that target loads into the real
// sandboxed app; the SPM test host does not reproduce the app sandbox.
final class OtherInputActivityMonitorSandboxTests: XCTestCase {
    func testProcessListReachableUnderAppSandbox() {
        let reachability = OtherInputActivityMonitor.probeProcessListReachability()
        XCTAssertEqual(
            reachability.status, noErr,
            "kAudioHardwarePropertyProcessObjectList query returned OSStatus \(reachability.status) under App Sandbox — the per-process mic API is blocked, so both mic cues are inert. The probe found \(reachability.count) audio process object(s)."
        )
        // The shared probe must also run without trapping under the sandbox.
        _ = OtherInputActivityMonitor.othersUsingMic()
    }
}
