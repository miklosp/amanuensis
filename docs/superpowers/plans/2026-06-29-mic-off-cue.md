# Mic-off cue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While recording, when the app that was using the microphone (a meeting) releases it, show a floating cue offering to stop recording — the mirror of the existing mic-on cue.

**Architecture:** A new pure state machine (`MicOffCuePolicy`) decides when to show/hide the cue from edge events; a new CoreAudio monitor (`OtherInputActivityMonitor`) detects whether any process *other than us* is capturing the mic (which works while we hold the mic ourselves, unlike the device-level signal); `AppCoordinator` wires them together and runs the monitor only while recording. The same per-process probe also replaces the on-cue's `dictation.phase` guard. The cue UI reuses a generalized floating-panel controller.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSPanel`), CoreAudio HAL (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyPID`), Swift Testing. Local SPM package `Packages/AudioPipeline` (modules `RecordingCore`, `AppSettings`); app target `Amanuensis`.

**Spec:** `docs/superpowers/specs/2026-06-29-mic-off-cue-design.md`

**Worktree:** All paths below are relative to the worktree root `/Users/miklos/Code/audio-pipeline/.worktrees/mic-off-cue` (branch `feat/mic-off-cue`).

## Global Constraints

- Deployment target macOS 26.3; Swift 6.2.
- **Default actor isolation is `MainActor`** — types/functions are implicitly `@MainActor`. CoreAudio reads that must run off-main (none here are required off-main, but the probe must be callable from any context) are marked `nonisolated`.
- Strict concurrency on (`SWIFT_APPROACHABLE_CONCURRENCY`, member-import-visibility). Closures handed to CoreAudio / stored across actor hops must be `@Sendable`.
- App Sandbox is on. **No new entitlements** — per-process HAL reads are expected to need none (the device-level read already does not). This is a runtime risk; see Risk note at the end.
- Conventional commits (`feat:`, `test:`, `refactor:`, `docs:`). End every commit message with the trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **UI copy, verbatim:** cue title `Meeting ended`, cue subtitle `Stop recording`; settings toggle label `Offer to stop recording when the meeting ends`.
- **Settings key, verbatim:** `suggestStoppingWhenMeetingEnds` (default `true`).
- Cue tile width `174`, auto-dismiss `8` s, debounce `1500` ms, poll interval `1500` ms (match the on-cue).

## Build & test commands (this environment)

- **SPM tests/build (autonomous, in-sandbox):** prefix with `--disable-sandbox`, e.g.
  `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter <Suite>`
  `swift build --disable-sandbox --package-path Packages/AudioPipeline`
  (Drop `--disable-sandbox` outside the sandbox.)
- **App-target build:** `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`.
  ⚠️ `/usr/bin/xcodebuild` self-refuses inside this sandbox; the helper routes it through the outside-sandbox Hammerspoon daemon. **In the current environment the helper scripts are absent**, so app-target build/compile verification (Tasks 4–7) must run on a machine with the daemon (the user's machine). The RecordingCore/AppSettings tasks (1–3) verify autonomously via `swift`.

---

## File Structure

**New:**
- `Packages/AudioPipeline/Sources/RecordingCore/MicOffCuePolicy.swift` — pure decision state machine.
- `Packages/AudioPipeline/Sources/RecordingCore/OtherInputActivityMonitor.swift` — per-process mic-use probe + poll monitor.
- `Packages/AudioPipeline/Tests/RecordingCoreTests/MicOffCuePolicyTests.swift` — policy tests.
- `Amanuensis/UI/CueCard.swift` — shared styled cue tile (the glass capsule + action button + close badge), parameterized by icon/title/subtitle/actions.
- `Amanuensis/UI/MicOffCueView.swift` — off-cue: a thin `CueCard` wrapper.
- `Amanuensis/UI/FloatingCueController.swift` — generalized panel controller (renamed from `MicCueController`).

**Modified:**
- `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` — new toggle.
- `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift` — toggle tests.
- `Amanuensis/UI/MicCueView.swift` — rebuilt as a thin `CueCard` wrapper (interface unchanged).
- `Amanuensis/AppCoordinator.swift` — off-cue wiring + on-cue guard removal + controller rename.
- `Amanuensis/UI/SettingsView.swift` — second toggle.

**Deleted:**
- `Amanuensis/UI/MicCueController.swift` — replaced by `FloatingCueController.swift`.

---

## Task 1: `MicOffCuePolicy` (pure state machine)

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/MicOffCuePolicy.swift`
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/MicOffCuePolicyTests.swift`

**Interfaces:**
- Produces: `public struct MicOffCuePolicy: Sendable` with `public enum Action: Equatable, Sendable { case none, startDebounce, showCue, hideCue }`; `public init(enabled: Bool = true)`; mutating events `enabledChanged(_ value: Bool) -> Action`, `recordingChanged(isRecording: Bool) -> Action`, `othersUsingMicChanged(_ others: Bool) -> Action`, `debounceElapsed() -> Action`, `cueDismissed() -> Action`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/RecordingCoreTests/MicOffCuePolicyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter MicOffCuePolicyBehavior`
Expected: FAIL — compile error `cannot find 'MicOffCuePolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/AudioPipeline/Sources/RecordingCore/MicOffCuePolicy.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter MicOffCuePolicyBehavior`
Expected: PASS — all 14 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/MicOffCuePolicy.swift \
        Packages/AudioPipeline/Tests/RecordingCoreTests/MicOffCuePolicyTests.swift
git commit -m "$(cat <<'EOF'
feat: add MicOffCuePolicy decision state machine

Mirror of MicCuePolicy: arms on the falling edge of "another app is using
the mic" while recording, offers to stop. Pure, fully unit-tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `OtherInputActivityMonitor` (per-process probe + poll monitor)

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/OtherInputActivityMonitor.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public nonisolated static func othersUsingMic(excludingPID pid: pid_t = getpid()) -> Bool` — true iff some process other than `pid` is running audio input. Reused by the on-cue in Task 6.
  - `@MainActor public final class OtherInputActivityMonitor` with `public init(pollInterval: Duration = .milliseconds(1500))`, `public func start(onChange: @escaping @Sendable @MainActor (Bool) -> Void)` (idempotent; reports baseline immediately then on every change), `public func stop()`.

> No unit test: this is CoreAudio IO with no deterministic fixture (same as `MicActivityMonitor`, which has none). The gate is that it **compiles under strict concurrency**, plus manual verification later. Do not invent an environment-dependent test.

- [ ] **Step 1: Write the implementation**

Create `Packages/AudioPipeline/Sources/RecordingCore/OtherInputActivityMonitor.swift`:

```swift
import CoreAudio
import Foundation
import os

// Detects whether any process OTHER than us is currently capturing the
// microphone, via the per-process Core Audio HAL API (macOS 14.4+):
// kAudioHardwarePropertyProcessObjectList → per-process
// kAudioProcessPropertyIsRunningInput, excluding our own PID. Unlike
// MicActivityMonitor (device-level IsRunningSomewhere), this stays meaningful
// while WE hold the mic — which the mic-off cue needs, since recording opens
// our own mic. We only read HAL properties, so this trips no privacy indicator.
//
// The instance polls on a timer (run only while recording) and reports changes.
// The static probe is also reused by the mic-ON cue to exclude our own usage.
// RecordingCore is nonisolated-by-default, so the class is explicitly @MainActor
// and the poll task reports on the main actor.
@MainActor
public final class OtherInputActivityMonitor {
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration

    public init(pollInterval: Duration = .milliseconds(1500)) {
        self.pollInterval = pollInterval
    }

    // Idempotent: a second start() while already running is ignored. Reports the
    // baseline immediately, then only when the value changes.
    public func start(onChange: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { @MainActor in
            var last: Bool?
            while !Task.isCancelled {
                let others = Self.othersUsingMic()
                if others != last {
                    last = others
                    onChange(others)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Stateless probe (shared with the mic-ON cue)

    // True iff some process other than `pid` is currently running audio input.
    public nonisolated static func othersUsingMic(excludingPID pid: pid_t = getpid()) -> Bool {
        for process in processObjectIDs() {
            guard processPID(process) != pid else { continue }
            if isRunningInput(process) { return true }
        }
        return false
    }

    // MARK: - nonisolated Core Audio helpers

    nonisolated private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        )
        guard dataStatus == noErr else { return [] }
        return ids
    }

    nonisolated private static func processPID(_ process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        guard status == noErr else { return -1 }
        return pid
    }

    nonisolated private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    nonisolated private static let log = Logger(
        subsystem: "work.miklos.amanuensis", category: "otherinputmonitor"
    )
}
```

- [ ] **Step 2: Verify it compiles under strict concurrency**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: Build succeeds with no warnings about Sendable/actor isolation. (If `kAudioProcessProperty*` symbols are unresolved, confirm `import CoreAudio` resolves them on the toolchain — they are part of CoreAudio on macOS 14.4+.)

- [ ] **Step 3: Run the existing SPM suite to confirm nothing regressed**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (Task 1 tests + all pre-existing suites).

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/OtherInputActivityMonitor.swift
git commit -m "$(cat <<'EOF'
feat: add OtherInputActivityMonitor (per-process mic-use detection)

Per-process HAL probe (excludes our own PID) + poll-while-recording monitor.
Stays meaningful while we hold the mic, which the mic-off cue needs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `AppSettings.suggestStoppingWhenMeetingEnds`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `public var suggestStoppingWhenMeetingEnds: Bool` on `AppSettings`, default `true`, persisted under key `"suggestStoppingWhenMeetingEnds"`.

- [ ] **Step 1: Write the failing tests**

In `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`, add the key to the `PersistedKey` enum (after the `suggestRecordingWhenMicInUse` line):

```swift
    static let suggestStoppingWhenMeetingEnds = "suggestStoppingWhenMeetingEnds"
```

And add these tests inside `@Suite struct AppSettingsBehavior` (after `suggestRecordingWhenMicInUse_persistedFalse_loadsAsFalse`):

```swift
    @Test func suggestStoppingWhenMeetingEnds_defaultsTrue() {
        withIsolatedDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.suggestStoppingWhenMeetingEnds == true)
        }
    }

    @Test func suggestStoppingWhenMeetingEnds_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.suggestStoppingWhenMeetingEnds = false

            let second = AppSettings(defaults: defaults)
            #expect(second.suggestStoppingWhenMeetingEnds == false)
        }
    }

    @Test func suggestStoppingWhenMeetingEnds_persistedFalse_loadsAsFalse() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PersistedKey.suggestStoppingWhenMeetingEnds)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.suggestStoppingWhenMeetingEnds == false)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppSettingsBehavior`
Expected: FAIL — compile error `value of type 'AppSettings' has no member 'suggestStoppingWhenMeetingEnds'`.

- [ ] **Step 3: Add the property**

In `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`, add the stored property after the `suggestRecordingWhenMicInUse` property block (before `dictation`):

```swift
    // When true, while recording, Amanuensis watches for the app that was using
    // the mic to release it (meeting ended) and shows a cue offering to stop
    // recording. Default true.
    public var suggestStoppingWhenMeetingEnds: Bool {
        didSet {
            defaults.set(suggestStoppingWhenMeetingEnds,
                         forKey: Keys.suggestStoppingWhenMeetingEnds)
        }
    }
```

In `init`, after the `suggestRecordingWhenMicInUse` load block (before the `dictation` load block):

```swift
        if defaults.object(forKey: Keys.suggestStoppingWhenMeetingEnds) != nil {
            suggestStoppingWhenMeetingEnds = defaults.bool(forKey: Keys.suggestStoppingWhenMeetingEnds)
        } else {
            suggestStoppingWhenMeetingEnds = true
        }
```

In the private `Keys` enum, after `suggestRecordingWhenMicInUse`:

```swift
        static let suggestStoppingWhenMeetingEnds = "suggestStoppingWhenMeetingEnds"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppSettingsBehavior`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift \
        Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift
git commit -m "$(cat <<'EOF'
feat: add suggestStoppingWhenMeetingEnds setting (default on)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Shared `CueCard` + rebuild `MicCueView` + add `MicOffCueView`

Extract the duplicated cue-tile styling into one parameterized `CueCard`, rebuild the existing `MicCueView` on it (interface unchanged), and add `MicOffCueView` on it. No styling is duplicated — `CueCard` is the single styled component; the two cue views are 4-line wrappers.

**Files:**
- Create: `Amanuensis/UI/CueCard.swift`
- Create: `Amanuensis/UI/MicOffCueView.swift`
- Modify: `Amanuensis/UI/MicCueView.swift`

**Interfaces:**
- Consumes: `glassTile(in:)` view modifier from `Amanuensis/UI/GlassPanel.swift` (already used by the current `MicCueView`).
- Produces:
  - `struct CueCard: View` with `let systemImage: String`, `let title: String`, `let subtitle: String`, `let onAction: () -> Void`, `let onDismiss: () -> Void`.
  - `struct MicCueView: View` — unchanged interface: `let onStart: () -> Void`, `let onDismiss: () -> Void`.
  - `struct MicOffCueView: View` with `let onStop: () -> Void`, `let onDismiss: () -> Void`.

> App-target files (no logic to unit-test). Build verification is controller-handled via the xcode-build daemon (the helper scripts are gone — see "Build & test commands"). Implement, commit, and self-review for compile-correctness by inspection; report build as controller-verified.

- [ ] **Step 1: Create the shared `CueCard`**

Create `Amanuensis/UI/CueCard.swift` — this is the existing `MicCueView` body, generalized over icon/title/subtitle/action:

```swift
import SwiftUI

// The shared Control-Center-style cue tile used by both the mic-on and mic-off
// cues: a glassy, pointer-reactive Liquid Glass capsule with a red circular
// action button on the left and a two-line label on the right. The tint and
// text follow the system appearance, flipping together between light and dark.
// Hovering reveals a notification-style close badge in the top-left corner and
// pulses the action button. Tapping the action button invokes onAction; the
// close badge or anywhere else on the capsule invokes onDismiss. Rendered
// inside FloatingCueController's NSPanel.
struct CueCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let onAction: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            actionButton

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(width: 174)
        .glassTile(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { onDismiss() }
        .overlay(alignment: .topLeading) {
            if hovering { closeBadge }
        }
        .padding(8)   // room for the close badge to overhang the corner
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(.snappy(duration: 0.15)) { hovering = isHovering }
        }
    }

    private var actionButton: some View {
        Button(action: onAction) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(pulse ? Color.red.mix(with: .white, by: 0.45) : .red, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { pulse = false }
            }
        }
    }

    private var closeBadge: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .offset(x: -7, y: -7)
        .transition(.scale.combined(with: .opacity))
    }
}
```

- [ ] **Step 2: Rebuild `MicCueView` as a thin wrapper**

Replace the entire contents of `Amanuensis/UI/MicCueView.swift` with:

```swift
import SwiftUI

// The floating cue shown when another app starts using the mic (a likely
// meeting), offering to start recording. A thin CueCard wrapper — see CueCard
// for the styling. Rendered inside FloatingCueController's NSPanel.
struct MicCueView: View {
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CueCard(
            systemImage: "mic.fill",
            title: "Mic in use",
            subtitle: "Start recording",
            onAction: onStart,
            onDismiss: onDismiss
        )
    }
}
```

- [ ] **Step 3: Create `MicOffCueView` as a thin wrapper**

Create `Amanuensis/UI/MicOffCueView.swift`:

```swift
import SwiftUI

// The floating cue shown when the app that was using the mic (a meeting)
// releases it while we are recording, offering to stop recording. A thin
// CueCard wrapper — see CueCard for the styling. Rendered inside
// FloatingCueController's NSPanel.
struct MicOffCueView: View {
    let onStop: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CueCard(
            systemImage: "stop.fill",
            title: "Meeting ended",
            subtitle: "Stop recording",
            onAction: onStop,
            onDismiss: onDismiss
        )
    }
}
```

- [ ] **Step 4: Build the app target**

Build verification is controller-handled (see "Build & test commands"). Expected: build succeeds; the on-cue renders identically to before (same `CueCard` styling), and `MicOffCueView` is available for Task 6 to wire up.

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/UI/CueCard.swift Amanuensis/UI/MicCueView.swift Amanuensis/UI/MicOffCueView.swift
git commit -m "$(cat <<'EOF'
feat: extract shared CueCard; add MicOffCueView

CueCard holds the cue-tile styling once; MicCueView (unchanged interface)
and the new MicOffCueView are thin wrappers over it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Generalize the panel controller into `FloatingCueController`

Rename `MicCueController` → `FloatingCueController` and make it host an injected SwiftUI view, then point the existing on-cue call site at the new API. On-cue behavior is unchanged.

**Files:**
- Create: `Amanuensis/UI/FloatingCueController.swift`
- Delete: `Amanuensis/UI/MicCueController.swift`
- Modify: `Amanuensis/AppCoordinator.swift` (member declaration + on-cue `apply(.showCue)` + `setMicCueEnabled` hide call)

**Interfaces:**
- Consumes: `MicCueView` (from Task's predecessor codebase).
- Produces: `@MainActor final class FloatingCueController` with `init(autoDismissAfter: TimeInterval = 8)`, `func show<Content: View>(onAutoDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content)`, `func hide()`.

- [ ] **Step 1: Create `FloatingCueController`**

Create `Amanuensis/UI/FloatingCueController.swift`:

```swift
import AppKit
import SwiftUI

// Owns a single non-activating floating NSPanel pinned top-right under the menu
// bar, hosting an injected SwiftUI cue view. Auto-dismisses after
// `autoDismissAfter` seconds, invoking onAutoDismiss. The panel never activates
// the app (it's a menu-bar accessory), so it won't steal focus from a meeting.
// Shared by the mic-on and mic-off cues — they never overlap in time (idle vs
// recording), so one shared instance also guarantees at most one cue is visible.
@MainActor
final class FloatingCueController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let autoDismissAfter: TimeInterval

    init(autoDismissAfter: TimeInterval = 8) {
        self.autoDismissAfter = autoDismissAfter
    }

    // Shows `content`. The caller wires the content's buttons to call hide()
    // plus their own handlers. onAutoDismiss runs when the auto-dismiss timer
    // fires (mirror the ✕ path so the driving policy stays in sync). Enforces a
    // single instance.
    func show<Content: View>(
        onAutoDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        hide()   // enforce a single instance

        let hosting = NSHostingView(rootView: content())
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.alphaValue = 0
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.autoDismissAfter))
            } catch {
                return   // cancelled by hide()
            }
            guard self.panel != nil else { return }
            self.hide()
            onAutoDismiss()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel else { return }
        self.panel = nil   // release immediately; single-instance stays enforced
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let inset: CGFloat = 12
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - inset,
            y: visible.maxY - size.height - inset
        ))
    }
}
```

- [ ] **Step 2: Delete the old controller**

```bash
git rm Amanuensis/UI/MicCueController.swift
```

- [ ] **Step 3: Update `AppCoordinator` to use `FloatingCueController`**

In `Amanuensis/AppCoordinator.swift`, change the member declaration (in the "Mic-in-use cue" group):

Replace:
```swift
    private let micCueController = MicCueController()
```
with:
```swift
    private let cueController = FloatingCueController()
```

In `setMicCueEnabled(_:)`, replace `micCueController.hide()` with `cueController.hide()`.

In `apply(_ action: MicCuePolicy.Action)`, replace the entire `.showCue` case body:

```swift
        case .showCue:
            cueController.show(onAutoDismiss: { [weak self] in
                guard let self else { return }
                self.apply(self.micCuePolicy.cueDismissed())
            }) {
                MicCueView(
                    onStart: { [weak self] in
                        self?.cueController.hide()
                        self?.startFromMicCue()
                    },
                    onDismiss: { [weak self] in
                        guard let self else { return }
                        self.cueController.hide()
                        self.apply(self.micCuePolicy.cueDismissed())
                    }
                )
            }
```

In the `.hideCue` case, replace `micCueController.hide()` with `cueController.hide()`.

- [ ] **Step 4: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds. On-cue still shows/hides as before (the wiring is equivalent — Start hides + starts; close/tap/auto-dismiss hides + feeds `cueDismissed`).

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/UI/FloatingCueController.swift Amanuensis/AppCoordinator.swift
git rm Amanuensis/UI/MicCueController.swift
git commit -m "$(cat <<'EOF'
refactor: generalize MicCueController into FloatingCueController

Hosts an injected SwiftUI cue view so both cues share one panel controller.
On-cue behavior unchanged.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire the off-cue into `AppCoordinator` (+ remove the on-cue dictation guard)

**Files:**
- Modify: `Amanuensis/AppCoordinator.swift`

**Interfaces:**
- Consumes: `MicOffCuePolicy` (Task 1), `OtherInputActivityMonitor` (Task 2), `MicOffCueView` (Task 4), `FloatingCueController` (Task 5), `AppSettings.suggestStoppingWhenMeetingEnds` (Task 3).
- Produces: `func setMicOffCueEnabled(_ enabled: Bool)` (called by `SettingsView` in Task 7).

- [ ] **Step 1: Add the off-cue members**

In `Amanuensis/AppCoordinator.swift`, in the "Mic-in-use cue" member group (right after the `lastReportedCoordinatorIdle` line), add:

```swift
    // Mic-off cue (offer to stop recording when the meeting ends).
    private let otherInputMonitor = OtherInputActivityMonitor()
    private var micOffCuePolicy = MicOffCuePolicy()
    private var micOffDebounceTask: Task<Void, Never>?
    private var lastReportedRecording = false
```

- [ ] **Step 2: Seed the off-cue policy in `init`**

In `init`, right after the existing on-cue seeding (`_ = micCuePolicy.enabledChanged(settings.suggestRecordingWhenMicInUse)` and its `micMonitor.start` block), add:

```swift
        // Seed the mic-off cue policy. Its monitor starts only when recording
        // begins (see notifyRecordingActivity), so nothing to start here.
        _ = micOffCuePolicy.enabledChanged(settings.suggestStoppingWhenMeetingEnds)
```

- [ ] **Step 3: Remove the on-cue dictation guard, route through the per-process probe**

Replace the entire `handleMicRunning` method:

```swift
    private func handleMicRunning(_ deviceRunning: Bool) {
        // A process OTHER than us is using the mic — exclude our own PID so our
        // own dictation/recording never arms the cue. (Replaces the former
        // `dictation.phase == .idle` guard.)
        let others = deviceRunning && OtherInputActivityMonitor.othersUsingMic()
        apply(micCuePolicy.micRunningChanged(others))
    }
```

- [ ] **Step 4: Extend `notifyRecordingActivity` to drive the off-cue + monitor lifecycle**

Replace the entire `notifyRecordingActivity` method:

```swift
    // Keeps both cue policies in sync with the recorder lifecycle. Called on
    // entry to .starting and from defers on every exit path. The on-cue tracks
    // idleness; the off-cue tracks the .recording state (a separate edge —
    // .starting→.recording is not an idleness flip) and gates its per-process
    // poll monitor to the recording window.
    private func notifyRecordingActivity() {
        let idle = (status == .idle)
        if idle != lastReportedCoordinatorIdle {
            lastReportedCoordinatorIdle = idle
            apply(micCuePolicy.recordingActivityChanged(isIdle: idle))
        }

        let recording = (status == .recording)
        if recording != lastReportedRecording {
            lastReportedRecording = recording
            applyOffCue(micOffCuePolicy.recordingChanged(isRecording: recording))
            if recording && settings.suggestStoppingWhenMeetingEnds {
                otherInputMonitor.start { [weak self] others in
                    guard let self else { return }
                    self.applyOffCue(self.micOffCuePolicy.othersUsingMicChanged(others))
                }
            } else {
                otherInputMonitor.stop()
            }
        }
    }
```

- [ ] **Step 5: Add `applyOffCue`, `setMicOffCueEnabled`, and `stopFromMicOffCue`**

Add these methods right after the existing `startFromMicCue()` method:

```swift
    func setMicOffCueEnabled(_ enabled: Bool) {
        applyOffCue(micOffCuePolicy.enabledChanged(enabled))
        if enabled {
            // Start the monitor immediately if we are already recording.
            if status == .recording {
                otherInputMonitor.start { [weak self] others in
                    guard let self else { return }
                    self.applyOffCue(self.micOffCuePolicy.othersUsingMicChanged(others))
                }
            }
        } else {
            micOffDebounceTask?.cancel()
            micOffDebounceTask = nil
            otherInputMonitor.stop()
            cueController.hide()
        }
    }

    // Executes a MicOffCuePolicy.Action. Mirrors apply(_:) for the on-cue.
    private func applyOffCue(_ action: MicOffCuePolicy.Action) {
        switch action {
        case .none:
            break
        case .startDebounce:
            micOffDebounceTask?.cancel()
            micOffDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                self.applyOffCue(self.micOffCuePolicy.debounceElapsed())
            }
        case .showCue:
            cueController.show(onAutoDismiss: { [weak self] in
                guard let self else { return }
                self.applyOffCue(self.micOffCuePolicy.cueDismissed())
            }) {
                MicOffCueView(
                    onStop: { [weak self] in
                        self?.cueController.hide()
                        self?.stopFromMicOffCue()
                    },
                    onDismiss: { [weak self] in
                        guard let self else { return }
                        self.cueController.hide()
                        self.applyOffCue(self.micOffCuePolicy.cueDismissed())
                    }
                )
            }
        case .hideCue:
            micOffDebounceTask?.cancel()
            micOffDebounceTask = nil
            cueController.hide()
        }
    }

    private func stopFromMicOffCue() {
        Task { @MainActor in await self.stopRecording() }
    }
```

- [ ] **Step 6: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds. No "unused" warnings (the dictation guard removal leaves `dictation` still used elsewhere).

- [ ] **Step 7: Run the SPM suite (sanity — nothing in the package changed, but confirm)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Amanuensis/AppCoordinator.swift
git commit -m "$(cat <<'EOF'
feat: wire mic-off cue into AppCoordinator

Run OtherInputActivityMonitor only while recording; drive MicOffCuePolicy;
show MicOffCueView via the shared controller; stop recording on confirm.
Also route the on-cue through the per-process probe and drop its dictation
guard (our own usage is now excluded by PID).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add the second toggle to `SettingsView`

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `AppSettings.suggestStoppingWhenMeetingEnds` (Task 3), `AppCoordinator.setMicOffCueEnabled` (Task 6).

- [ ] **Step 1: Add the toggle**

In `Amanuensis/UI/SettingsView.swift`, inside the `Section("Meetings")`, immediately after the existing `suggestRecordingWhenMicInUse` toggle (after its `.onChange { ... }` modifier closes), add:

```swift
                Toggle(isOn: $settings.suggestStoppingWhenMeetingEnds) {
                    VStack(alignment: .leading) {
                        Text("Offer to stop recording when the meeting ends")
                        Text("While recording, when the app that was using the microphone releases it, Amanuensis shows a cue to stop recording. Watches running processes other than itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.suggestStoppingWhenMeetingEnds) { _, newValue in
                    coordinator.setMicOffCueEnabled(newValue)
                }
```

- [ ] **Step 2: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Amanuensis/UI/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat: add "offer to stop recording when the meeting ends" setting toggle

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all tasks)

- [ ] **Full SPM suite:** `swift test --disable-sandbox --package-path Packages/AudioPipeline` → all green.
- [ ] **App build:** `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` → succeeds (needs the daemon / user's machine).
- [ ] **Manual smoke (user's machine, real meeting app):**
  1. Enable both Meetings toggles. Join a call (e.g. another app grabs the mic) → mic-**on** cue appears → click record.
  2. End the call (the other app releases the mic) → within ~1.5–3 s the mic-**off** cue ("Meeting ended" / "Stop recording") appears top-right.
  3. Click stop → recording stops and converts as normal. Re-join + re-end → cue fires again (re-arm works).
  4. Start a manual recording with no other app on the mic → off-cue never appears (no falling edge).
  5. Trigger dictation while idle → on-cue does **not** appear (per-PID exclusion; confirms the dictation-guard removal).

---

## Self-Review

**Spec coverage:**
- Per-process detection excluding self → Task 2 (`othersUsingMic(excludingPID:)`). ✓
- Poll-while-recording monitor → Task 2 (instance) + Task 6 (lifecycle in `notifyRecordingActivity`). ✓
- Transition-based "any recording" scope → Task 1 (`MicOffCuePolicy` falling-edge logic; `manualRecording_noOthers_neverArms` test). ✓
- Separate setting, default on → Task 3. ✓
- `MicOffCueView` stop button + copy → Task 4. ✓
- Generalized shared controller → Task 5. ✓
- Coordinator wiring + on-cue guard removal → Task 6. ✓
- Settings toggle in Meetings section → Task 7. ✓
- Error handling (status≠noErr ⇒ false; failed enumeration ⇒ []/false) → Task 2 helpers. ✓
- TDD core via SPM tests → Tasks 1, 3. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code; every command has expected output. ✓

**Type consistency:** `othersUsingMic(excludingPID:)`, `othersUsingMicChanged(_:)`, `recordingChanged(isRecording:)`, `setMicOffCueEnabled(_:)`, `applyOffCue(_:)`, `cueController`, `FloatingCueController.show(onAutoDismiss:content:)`, `MicOffCueView(onStop:onDismiss:)` — names match across Tasks 1, 2, 4, 5, 6, 7. ✓

## Risk note

The per-process HAL reads (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyPID`) are assumed to work under App Sandbox with the existing audio-input entitlement and no new entitlement (the device-level read already does). If `othersUsingMic()` always returns `false` under sandbox during the manual smoke test (Task 6/Final), check the unified log (`OSLog` category `otherinputmonitor`) and `docs/permissions.md`; the fallback would be an added entitlement or a TCC-gated path, to be scoped then. This does not affect the on-cue (it keeps the device-level listener as its trigger; the probe only *refines* it).
