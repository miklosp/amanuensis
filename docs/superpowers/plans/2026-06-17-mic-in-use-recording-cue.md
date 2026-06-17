# Mic-in-use recording cue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When another app starts using the microphone (a likely meeting), show a subtle one-click floating HUD cue offering to start recording — gated by a Settings toggle (default on).

**Architecture:** A pure, unit-tested `MicCuePolicy` state machine decides *when* to show/hide the cue. Two effectful edges feed/serve it: `MicActivityMonitor` (Core Audio property listener on the default input device's `kAudioDevicePropertyDeviceIsRunningSomewhere`) and `MicCueController` (a non-activating `NSPanel`). `AppCoordinator` wires them, owns the debounce/auto-dismiss timing, and routes the cue's "Start" to its existing `startRecording()`. This mirrors the existing `RecorderStateMachine` (pure) + coordinator (effects) split.

**Tech Stack:** Swift 6.2, swift-testing, Core Audio (HAL property listeners), AppKit `NSPanel` + SwiftUI `NSHostingView`, `@Observable` settings.

**Branch:** `feat/mic-in-use-recording-cue` (already created; the design spec is committed there).

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `Packages/AudioPipeline/Sources/RecordingCore/MicCuePolicy.swift` | Pure decision state machine | Create |
| `Packages/AudioPipeline/Tests/RecordingCoreTests/MicCuePolicyTests.swift` | Full unit coverage of the policy | Create |
| `Packages/AudioPipeline/Sources/RecordingCore/MicActivityMonitor.swift` | Core Audio mic-in-use listener | Create |
| `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` | New `suggestRecordingWhenMicInUse` pref | Modify |
| `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift` | Pref default + persistence tests | Modify |
| `Amanuensis/UI/MicCueView.swift` | SwiftUI HUD content | Create |
| `Amanuensis/UI/MicCueController.swift` | Non-activating `NSPanel` host + auto-dismiss | Create |
| `Amanuensis/AppCoordinator.swift` | Wire monitor + policy + controller; debounce | Modify |
| `Amanuensis/UI/SettingsView.swift` | Toggle | Modify |
| `Amanuensis/AmanuensisApp.swift` | Pass coordinator into `SettingsView` | Modify |

**Commands used throughout** (from the project root, inside the Claude Code sandbox unless noted):
- Run SPM tests: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
- Run a filtered SPM test: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter <regex>`
- Compile the SPM package: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
- Build the app target (routes through the xcode-build skill's outside-sandbox daemon — `/usr/bin/xcodebuild` self-refuses inside the sandbox): `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`

---

## Task 1: `MicCuePolicy` — pure decision state machine

The heart of the feature. Pure value type, `Sendable`, no timers/IO — exactly like `RecorderStateMachine`. Phases `idle → armed → shown → consumed`. Fires once per continuous mic session; arms only on a false→true edge while enabled and the coordinator is idle.

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/MicCuePolicy.swift`
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/MicCuePolicyTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/RecordingCoreTests/MicCuePolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import RecordingCore

@Suite struct MicCuePolicyBehavior {
    // Helper: seed a policy that has already observed mic=false (so the next
    // `true` is a genuine rising edge, not the baseline).
    private func seededFalse(enabled: Bool = true) -> MicCuePolicy {
        var p = MicCuePolicy(enabled: enabled)
        #expect(p.micRunningChanged(false) == .none)  // baseline
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter MicCuePolicyBehavior`
Expected: FAIL to compile — `cannot find 'MicCuePolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/AudioPipeline/Sources/RecordingCore/MicCuePolicy.swift`:

```swift
import Foundation

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
        guard !value else { return .none }   // enabling never retro-arms (no edge)
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

    public mutating func cueDismissed() -> Action {
        guard phase == .shown else { return .none }
        phase = .consumed
        return .none
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter MicCuePolicyBehavior`
Expected: PASS — all 11 tests green.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/MicCuePolicy.swift \
        Packages/AudioPipeline/Tests/RecordingCoreTests/MicCuePolicyTests.swift
git commit -m "feat(recording): add MicCuePolicy decision state machine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `AppSettings.suggestRecordingWhenMicInUse`

A new persisted Bool, default `true`, following the exact `keepOriginalCAF` pattern.

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`, add to the `PersistedKey` enum (after the `keepOriginalCAF` line):

```swift
    static let suggestRecordingWhenMicInUse = "suggestRecordingWhenMicInUse"
```

In `freshSuite_usesBuiltInDefaults()`, add after the existing `keepOriginalCAF` expectation:

```swift
            #expect(settings.suggestRecordingWhenMicInUse == true)
```

Add two new tests inside `@Suite struct AppSettingsBehavior` (after `keepOriginalCAF_persistedFalse_loadsAsFalse`):

```swift
    @Test func suggestRecordingWhenMicInUse_persistsAcrossInstances() {
        withIsolatedDefaults { defaults in
            let first = AppSettings(defaults: defaults)
            first.suggestRecordingWhenMicInUse = false

            let second = AppSettings(defaults: defaults)
            #expect(second.suggestRecordingWhenMicInUse == false)
        }
    }

    @Test func suggestRecordingWhenMicInUse_persistedFalse_loadsAsFalse() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PersistedKey.suggestRecordingWhenMicInUse)

            let settings = AppSettings(defaults: defaults)
            #expect(settings.suggestRecordingWhenMicInUse == false)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppSettingsBehavior`
Expected: FAIL to compile — `value of type 'AppSettings' has no member 'suggestRecordingWhenMicInUse'`.

- [ ] **Step 3: Write the implementation**

In `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`, add a stored property after the `keepOriginalCAF` block (after line 22):

```swift

    // When true, Amanuensis watches the default input device and shows a cue
    // offering to start recording whenever another app begins using the mic
    // (a likely meeting). Default true.
    public var suggestRecordingWhenMicInUse: Bool {
        didSet {
            defaults.set(suggestRecordingWhenMicInUse,
                         forKey: Keys.suggestRecordingWhenMicInUse)
        }
    }
```

In `init`, after the `keepOriginalCAF` defaulting block (after line 42):

```swift

        if defaults.object(forKey: Keys.suggestRecordingWhenMicInUse) != nil {
            suggestRecordingWhenMicInUse = defaults.bool(forKey: Keys.suggestRecordingWhenMicInUse)
        } else {
            suggestRecordingWhenMicInUse = true
        }
```

In the `Keys` enum, add after `keepOriginalCAF`:

```swift
        static let suggestRecordingWhenMicInUse = "suggestRecordingWhenMicInUse"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppSettingsBehavior`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift \
        Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift
git commit -m "feat(settings): add suggestRecordingWhenMicInUse preference

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `MicActivityMonitor` — Core Audio mic-in-use listener

Effectful edge. Watches the default input device's `kAudioDevicePropertyDeviceIsRunningSomewhere`, re-attaches when the default input device changes, and reports `Bool` changes to a MainActor callback. No SPM unit test (needs a real device); verified by compiling the package and, later, the manual smoke test in Task 7. The CA listener blocks are `@Sendable` and hop to the main actor via `Task { @MainActor in }` — the project's documented rule for audio-thread closures.

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/MicActivityMonitor.swift`

- [ ] **Step 1: Write the implementation**

Create `Packages/AudioPipeline/Sources/RecordingCore/MicActivityMonitor.swift`:

```swift
import CoreAudio
import Foundation
import os

// Watches whether the system's default input device is "running somewhere"
// (in use by any process) via kAudioDevicePropertyDeviceIsRunningSomewhere.
// We never open the mic ourselves — only read a HAL property — so this does
// not trip the mic privacy indicator. Used to detect a likely meeting (another
// app holding the mic) and offer to record.
//
// Scope limitation: only the *default* input device is tracked; a meeting on a
// non-default mic is not detected. RecordingCore is nonisolated-by-default, so
// this class is explicitly @MainActor and the CA listener blocks hop back to
// the main actor.
@MainActor
public final class MicActivityMonitor {
    private let queue = DispatchQueue(
        label: "work.miklos.amanuensis.micmonitor", qos: .utility
    )
    private var onChange: (@Sendable @MainActor (Bool) -> Void)?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {}

    // Idempotent: a second start() while already running is ignored.
    public func start(onChange: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        installDefaultDeviceListener()
        attachToCurrentDefaultInput()
    }

    public func stop() {
        removeDeviceListener()
        removeDefaultDeviceListener()
        onChange = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - default-input-device change listener

    private func installDefaultDeviceListener() {
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.removeDeviceListener()
                self.attachToCurrentDefaultInput()
            }
        }
        defaultDeviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status != noErr {
            Self.log.error("add default-input listener failed: \(status, privacy: .public)")
        }
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        defaultDeviceListenerBlock = nil
    }

    // MARK: - per-device IsRunningSomewhere listener

    private func attachToCurrentDefaultInput() {
        guard let device = Self.defaultInputDeviceID() else {
            Self.log.error("no default input device")
            return
        }
        deviceID = device

        var address = Self.runningAddress
        let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            let running = Self.isRunningSomewhere(device)
            Task { @MainActor in self?.onChange?(running) }
        }
        deviceListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        if status != noErr {
            Self.log.error("add IsRunningSomewhere listener failed: \(status, privacy: .public)")
            return
        }

        // Report the current state (the baseline on first attach, or the new
        // device's state after a default-device change).
        let running = Self.isRunningSomewhere(device)
        let callback = onChange
        Task { @MainActor in callback?(running) }
    }

    private func removeDeviceListener() {
        guard deviceID != kAudioObjectUnknown, let block = deviceListenerBlock else { return }
        var address = Self.runningAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        deviceListenerBlock = nil
    }

    // MARK: - nonisolated Core Audio helpers

    nonisolated private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func defaultInputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    nonisolated private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = runningAddress
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    nonisolated private static let log = Logger(
        subsystem: "work.miklos.amanuensis", category: "micmonitor"
    )
}
```

- [ ] **Step 2: Compile the package to verify it builds**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: `Build complete!` with no errors.
If a Sendable diagnostic appears on either listener block, confirm the `@Sendable [weak self]` capture is present (it already is above) — this matches `ProcessTapRecorder`'s IO-proc block pattern.

- [ ] **Step 3: Run the full SPM suite (nothing regressed)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/MicActivityMonitor.swift
git commit -m "feat(recording): add MicActivityMonitor for mic-in-use detection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `MicCueView` + `MicCueController` — the floating HUD

App-target UI. `MicCueView` is the SwiftUI content; `MicCueController` hosts it in a non-activating `NSPanel` pinned top-right under the menu bar, with a Task-based ~8 s auto-dismiss. Verified by building the app target; behaviour confirmed in Task 7.

**Files:**
- Create: `Amanuensis/UI/MicCueView.swift`
- Create: `Amanuensis/UI/MicCueController.swift`

New `.swift` files under `Amanuensis/UI/` are auto-registered by the `PBXFileSystemSynchronizedRootGroup` — no `project.pbxproj` edit needed.

- [ ] **Step 1: Create the SwiftUI HUD content**

Create `Amanuensis/UI/MicCueView.swift`:

```swift
import SwiftUI

// The floating cue shown when another app starts using the mic. Two actions:
// start recording, or dismiss. Rendered inside MicCueController's NSPanel.
struct MicCueView: View {
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mic in use")
                    .font(.headline)
                Button("Start recording", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Create the panel controller**

Create `Amanuensis/UI/MicCueController.swift`:

```swift
import AppKit
import SwiftUI

// Owns a single non-activating floating NSPanel that hosts MicCueView, pinned
// top-right under the menu bar. Auto-dismisses after `autoDismissAfter`
// seconds. Both auto-dismiss and the ✕ button invoke the caller's onDismiss;
// the Start button invokes onStart. The panel never activates the app (it's a
// menu-bar accessory), so it won't steal focus from the meeting.
@MainActor
final class MicCueController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private let autoDismissAfter: TimeInterval

    init(autoDismissAfter: TimeInterval = 8) {
        self.autoDismissAfter = autoDismissAfter
    }

    func show(onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()   // enforce a single instance

        let view = MicCueView(
            onStart: { [weak self] in self?.hide(); onStart() },
            onDismiss: { [weak self] in self?.hide(); onDismiss() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

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
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.autoDismissAfter))
            guard !Task.isCancelled, self.panel != nil else { return }
            self.hide()
            onDismiss()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
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

- [ ] **Step 3: Build the app target to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (`MicCueController`/`MicCueView` are unused by the app entry point yet — Swift does not warn on unused types, so this just confirms they compile.)

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/MicCueView.swift Amanuensis/UI/MicCueController.swift
git commit -m "feat(ui): add floating mic-in-use cue panel

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire monitor + policy + controller into `AppCoordinator`

The coordinator owns all three pieces, runs the debounce, keeps the policy's `coordinatorIdle` synced via a diffing helper called from `defer`s, and routes the cue's Start to the existing `startRecording()`.

**Files:**
- Modify: `Amanuensis/AppCoordinator.swift`

- [ ] **Step 1: Add stored properties**

In `Amanuensis/AppCoordinator.swift`, after `private let conversionService = RecordingConversionService()` (line 58):

```swift

    // Mic-in-use cue (auto-detect a likely meeting → offer to record).
    private let micMonitor = MicActivityMonitor()
    private var micCuePolicy = MicCuePolicy()
    private let micCueController = MicCueController()
    private var micDebounceTask: Task<Void, Never>?
    private var lastReportedCoordinatorIdle = true
```

- [ ] **Step 2: Wire startup at the end of `init`**

In `init`, immediately before its closing brace (after the `logs` do/catch block, after line 114):

```swift

        // Start the mic-in-use cue if enabled in settings.
        _ = micCuePolicy.enabledChanged(settings.suggestRecordingWhenMicInUse)
        if settings.suggestRecordingWhenMicInUse {
            micMonitor.start { [weak self] running in self?.handleMicRunning(running) }
        }
```

- [ ] **Step 3: Add the cue helper methods**

In `AppCoordinator`, after `flashRecordingActivity(_:)` (after line 307, before `enum JobRunError`):

```swift

    // MARK: - Mic-in-use cue

    func setMicCueEnabled(_ enabled: Bool) {
        apply(micCuePolicy.enabledChanged(enabled))
        if enabled {
            micMonitor.start { [weak self] running in self?.handleMicRunning(running) }
        } else {
            micMonitor.stop()
        }
    }

    private func handleMicRunning(_ running: Bool) {
        apply(micCuePolicy.micRunningChanged(running))
    }

    // Keeps the policy's idle/busy view in sync with the recorder lifecycle.
    // Called from defers in start/stopRecording so it runs on every exit path
    // (including early returns); only feeds the policy when idleness flips.
    private func notifyRecordingActivity() {
        let idle = (status == .idle)
        guard idle != lastReportedCoordinatorIdle else { return }
        lastReportedCoordinatorIdle = idle
        apply(micCuePolicy.recordingActivityChanged(isIdle: idle))
    }

    // Executes a MicCuePolicy.Action. May recurse (debounce → debounceElapsed).
    private func apply(_ action: MicCuePolicy.Action) {
        switch action {
        case .none:
            break
        case .startDebounce:
            micDebounceTask?.cancel()
            micDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                self.apply(self.micCuePolicy.debounceElapsed())
            }
        case .showCue:
            micCueController.show(
                onStart: { [weak self] in self?.startFromMicCue() },
                onDismiss: { [weak self] in
                    guard let self else { return }
                    self.apply(self.micCuePolicy.cueDismissed())
                }
            )
        case .hideCue:
            micDebounceTask?.cancel()
            micDebounceTask = nil
            micCueController.hide()
        }
    }

    private func startFromMicCue() {
        Task { @MainActor in await self.startRecording() }
    }
```

- [ ] **Step 4: Sync recording activity from the lifecycle methods**

Add `defer { notifyRecordingActivity() }` as the **first line** of `startRecording()` body (immediately after `func startRecording() async {`, before the `guard machine.start() ...` on line 128):

```swift
        defer { notifyRecordingActivity() }
```

Add the same as the **first line** of `stopRecording()` body (immediately after `func stopRecording() async {`, before the `guard machine.stop() ...` on line 169):

```swift
        defer { notifyRecordingActivity() }
```

- [ ] **Step 5: Build the app target to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Amanuensis/AppCoordinator.swift
git commit -m "feat(recording): wire mic-in-use cue into AppCoordinator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Settings toggle

Expose the preference in `SettingsView`, and have flipping it start/stop the monitor via the coordinator. `SettingsView` gains a `coordinator` dependency (the app entry point already holds it).

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift`
- Modify: `Amanuensis/AmanuensisApp.swift`

- [ ] **Step 1: Add the coordinator dependency and the toggle section**

In `Amanuensis/UI/SettingsView.swift`, change the stored properties (lines 5-6) from:

```swift
struct SettingsView: View {
    @Bindable var settings: AppSettings
```

to:

```swift
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator
```

Add a new `Section` after the existing `Section("After recording stops") { ... }` block (after line 30, before the closing `}` of the `Form`):

```swift
            Section("Meetings") {
                Toggle(isOn: $settings.suggestRecordingWhenMicInUse) {
                    VStack(alignment: .leading) {
                        Text("Offer to record when the mic is in use")
                        Text("When another app starts using the microphone (e.g. a meeting), Amanuensis shows a cue to start recording. Watches the default input device only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.suggestRecordingWhenMicInUse) { _, newValue in
                    coordinator.setMicCueEnabled(newValue)
                }
            }
```

Bump the frame height (line 33) from `height: 260` to `height: 360` to fit the new section:

```swift
        .frame(width: 480, height: 360)
```

- [ ] **Step 2: Pass the coordinator into the Settings scene**

In `Amanuensis/AmanuensisApp.swift`, change the `Settings` scene (lines 30-32) from:

```swift
        Settings {
            SettingsView(settings: coordinator.settings)
        }
```

to:

```swift
        Settings {
            SettingsView(settings: coordinator.settings, coordinator: coordinator)
        }
```

- [ ] **Step 3: Build the app target to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/SettingsView.swift Amanuensis/AmanuensisApp.swift
git commit -m "feat(settings): add mic-in-use cue toggle to Settings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Manual verification (app-hosted; needs a real audio device)

The policy is unit-tested; the live Core Audio monitor and the HUD panel need a running app and a real mic. Run the app and confirm behaviour.

**Files:** none (verification only).

- [ ] **Step 1: Build and launch**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Then find the product and launch it:
Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug -showBuildSettings | rg '^\s+BUILT_PRODUCTS_DIR'`
Run: `open <BUILT_PRODUCTS_DIR>/Amanuensis.app`

- [ ] **Step 2: Verify the cue appears on external mic use**

With the Settings toggle ON (default), open an app that uses the mic (e.g. Photo Booth, or join a meeting). Within ~1.5 s the HUD should slide in top-right with "Mic in use" + "Start recording". Confirm:
- It does **not** steal focus from the other app.
- Clicking **Start recording** begins a recording (menu-bar icon flips to `record.circle.fill`) and the HUD disappears.

- [ ] **Step 3: Verify dismiss + no-nag**

Trigger the cue again (stop+restart mic use). This time click **✕** (or wait ~8 s for auto-dismiss). Confirm the HUD goes away and does **not** reappear while the same mic session continues. End mic use and start a new session → the cue reappears.

- [ ] **Step 4: Verify self-suppression**

From the menu bar, choose **Start recording** directly (no cue). Confirm no cue appears from the app's own mic usage, during recording or after stopping (while a meeting may still hold the mic).

- [ ] **Step 5: Verify the toggle**

Open Settings → Meetings, turn the toggle **off**. Trigger external mic use → no cue. Turn it back **on** → cue returns on the next mic session.

- [ ] **Step 6: Confirm the SPM suite and app still build clean**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all PASS.
Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Note any deviations**

If the HUD position, debounce, or auto-dismiss feels off in practice, record the tuning in the design spec's amendments and adjust the constants (`1500` ms debounce in `AppCoordinator.apply`, `autoDismissAfter: 8` in `MicCueController.init`).

---

## Self-review notes

- **Spec coverage:** signal (`IsRunningSomewhere`) → Task 3; default-input + re-attach → Task 3; pure policy + tests → Task 1; debounce/auto-dismiss → Tasks 4–5; self-suppression → Task 1 tests + Task 5 `defer` wiring; HUD non-activating panel top-right → Task 4; settings toggle default-on → Tasks 2 & 6; error degradation (log + inert) → Task 3; deferred items (calendar/camera/app-detection) untouched. All spec sections map to a task.
- **Type consistency:** `MicCuePolicy.Action` cases (`none/startDebounce/showCue/hideCue`) and event methods (`enabledChanged/recordingActivityChanged/micRunningChanged/debounceElapsed/cueDismissed`) are identical across Tasks 1 and 5. `MicActivityMonitor.start(onChange:)`/`stop()`, `MicCueController.show(onStart:onDismiss:)`/`hide()`, and `AppSettings.suggestRecordingWhenMicInUse` names match every call site.
- **Entitlement caveat:** if Task 7 shows no cue ever fires, verify that reading `IsRunningSomewhere` is permitted under the App Sandbox; the app already holds microphone permission and we never open the device, so this is expected to work — but it's the first thing to check if the live monitor is silent.
