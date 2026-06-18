# Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Global push-to-talk / toggle dictation — press a configurable ⌘ trigger, speak, and have the transcribed text inserted at the cursor (clipboard fallback), staying within App Sandbox.

**Architecture:** Pure, unit-tested logic (gesture recognition, dictation state machine, settings, transcriber protocol) lives in a new `DictationCore` SPM package. Effectful edges — the `CGEventTap` hotkey monitor, synthetic-paste inserter, 16 kHz-WAV recorder, Jobs-backed batch transcriber, overlay panel, and menu-bar animation — live app-side and are wired by a `DictationCoordinator` hung off `AppCoordinator`, mirroring the existing mic-cue feature.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSPanel`/`NSPasteboard`), CoreGraphics (`CGEventTap`, `CGEvent.post`), AVFoundation (`AVAudioEngine`/`AVAudioConverter`), Swift Testing (`swift test`), existing `AudioPipelineJobs` (`AudioJobSending`, `KeychainStore`).

**Spec:** `docs/superpowers/specs/2026-06-18-dictation-design.md`. **Branch:** `feat/dictation` (already checked out).

---

## File Structure

**New SPM package files (`Packages/AudioPipeline/Sources/DictationCore/`):**
- `TriggerSide.swift` — `enum` left/right ⌘ + virtual keycodes.
- `InsertMode.swift` — `enum` autoInsert/clipboardOnly.
- `DictationError.swift` — error cases.
- `DictationSettings.swift` — `Codable` prefs aggregate + `.default`.
- `DictationTranscriber.swift` — the streaming-ready protocol.
- `ModifierGestureRecognizer.swift` — pure tap/hold + solo-guard recognizer.
- `DictationStateMachine.swift` — pure idle→listening→transcribing→inserting machine.
- `DictationTempStore.swift` — temp-dir naming + sweep (Foundation only).

**New SPM tests (`Packages/AudioPipeline/Tests/DictationCoreTests/`):** one file per logic type.

**New RecordingCore files:**
- `DictationRecorder.swift` + `DictationWAVWriter.swift` — 16 kHz mono WAV capture + RMS level.

**New app files (`Amanuensis/Dictation/`):**
- `BatchTranscriber.swift` — `DictationTranscriber` over an `AudioJobSending` handler.
- `HotkeyTapMonitor.swift` — `CGEventTap(.listenOnly)` → `triggerDown/Up/foreignInput`.
- `TextInserter.swift` — pasteboard + synthetic ⌘V.
- `DictationCoordinator.swift` — the brain; wires recognizer→machine→effects.

**New app UI (`Amanuensis/UI/`):**
- `DictationMenuBarLabel.swift` — state-driven animated menu-bar icon.
- `DictationOverlayController.swift` + `DictationOverlayView.swift` — bottom-center panel.

**Modified files:**
- `Packages/AudioPipeline/Package.swift` — add `DictationCore` product/target/test; `AppSettings` depends on `DictationCore`.
- `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` — add `dictation: DictationSettings`.
- `Amanuensis/AppCoordinator.swift` — construct/expose `DictationCoordinator`; add `allProviders`.
- `Amanuensis/AmanuensisApp.swift` — swap the menu-bar `label:` for `DictationMenuBarLabel`.
- `Amanuensis/UI/SettingsView.swift` — add the Dictation section + permission rows.
- Xcode project — link the `DictationCore` library product to the app target.

---

## Task 1: `DictationCore` package skeleton + wiring

**Files:**
- Modify: `Packages/AudioPipeline/Package.swift`
- Create: `Packages/AudioPipeline/Sources/DictationCore/Placeholder.swift`
- Create: `Packages/AudioPipeline/Tests/DictationCoreTests/SmokeTests.swift`

- [ ] **Step 1: Add the product, target, and test target to `Package.swift`**

In the `products:` array, after the `AppLog` line, add:

```swift
        .library(name: "DictationCore",     targets: ["DictationCore"]),
```

In the `targets:` array, add a target (after the `AppLog` target) and a test target (after `AppLogTests`):

```swift
    .target(name: "DictationCore", swiftSettings: nonisolatedSettings),
```

```swift
    .testTarget(
        name: "DictationCoreTests",
        dependencies: ["DictationCore"],
        swiftSettings: nonisolatedSettings
    ),
```

Also make `AppSettings` depend on `DictationCore` (it will store `DictationSettings` in Task 6). Replace the existing `AppSettings` target line:

```swift
    .target(name: "AppSettings",      swiftSettings: mainActorSettings),
```

with:

```swift
    .target(name: "AppSettings", dependencies: ["DictationCore"], swiftSettings: mainActorSettings),
```

- [ ] **Step 2: Create a placeholder source so the target compiles**

`Packages/AudioPipeline/Sources/DictationCore/Placeholder.swift`:

```swift
// DictationCore — pure, AppKit-free dictation logic. Real types added in later tasks.
```

- [ ] **Step 3: Write a smoke test**

`Packages/AudioPipeline/Tests/DictationCoreTests/SmokeTests.swift`:

```swift
import Testing
@testable import DictationCore

@Test func packageCompilesAndLinks() {
    #expect(true)
}
```

- [ ] **Step 4: Run the SPM suite to verify wiring**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationCoreTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Package.swift Packages/AudioPipeline/Sources/DictationCore Packages/AudioPipeline/Tests/DictationCoreTests
git commit -m "feat(dictation): scaffold DictationCore SPM package"
```

---

## Task 2: Core value types — `TriggerSide`, `InsertMode`, `DictationError`

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/TriggerSide.swift`
- Create: `Packages/AudioPipeline/Sources/DictationCore/InsertMode.swift`
- Create: `Packages/AudioPipeline/Sources/DictationCore/DictationError.swift`
- Create: `Packages/AudioPipeline/Tests/DictationCoreTests/TriggerSideTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/DictationCoreTests/TriggerSideTests.swift`:

```swift
import Testing
@testable import DictationCore

@Test func keyCodesMatchMacOSVirtualKeys() {
    #expect(TriggerSide.leftCommand.keyCode == 55)   // kVK_Command, 0x37
    #expect(TriggerSide.rightCommand.keyCode == 54)  // kVK_RightCommand, 0x36
}

@Test func triggerSideRoundTripsCodable() throws {
    let data = try JSONEncoder().encode(TriggerSide.rightCommand)
    #expect(try JSONDecoder().decode(TriggerSide.self, from: data) == .rightCommand)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TriggerSideTests`
Expected: FAIL (compile error: `TriggerSide` not found).

- [ ] **Step 3: Implement the three types**

`TriggerSide.swift`:

```swift
/// Which Command key is bound as the dictation trigger.
public enum TriggerSide: String, Codable, Sendable, CaseIterable {
    case leftCommand
    case rightCommand

    /// macOS virtual keycode reported by `flagsChanged` events.
    public var keyCode: Int64 {
        switch self {
        case .leftCommand:  return 55  // 0x37
        case .rightCommand: return 54  // 0x36
        }
    }
}
```

`InsertMode.swift`:

```swift
/// How a finished transcript reaches the focused app.
public enum InsertMode: String, Codable, Sendable, CaseIterable {
    case autoInsert     // synthetic ⌘V paste
    case clipboardOnly  // leave on clipboard, user pastes
}
```

`DictationError.swift`:

```swift
public enum DictationError: Error, Equatable, Sendable {
    case noProviderConfigured
    case unsupportedShape
    case transcriptionFailed(String)
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TriggerSideTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore Packages/AudioPipeline/Tests/DictationCoreTests
git commit -m "feat(dictation): add TriggerSide, InsertMode, DictationError"
```

---

## Task 3: `ModifierGestureRecognizer`

The pure tap-vs-hold + solo-guard recognizer. It carries no timer and no clock: the hold threshold is enforced by the coordinator's timer (Task 12), which calls `holdElapsed()`. The recognizer only tracks ordering.

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/ModifierGestureRecognizer.swift`
- Create: `Packages/AudioPipeline/Tests/DictationCoreTests/ModifierGestureRecognizerTests.swift`

- [ ] **Step 1: Write the failing tests**

`ModifierGestureRecognizerTests.swift`:

```swift
import Testing
@testable import DictationCore

@Test func quickTapEmitsToggle() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.triggerUp() == .toggle)
}

@Test func holdEmitsPTTStartThenEnd() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.holdElapsed() == .pttStart)
    #expect(r.triggerUp() == .pttEnd)
}

@Test func foreignKeyDuringPressCancelsAndSwallowsRelease() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.foreignInput() == .cancel)
    #expect(r.triggerUp() == .none)        // the ⌘ release after ⌘C must NOT toggle
}

@Test func holdElapsedWithoutTrackingIsNoop() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.holdElapsed() == .none)
}

@Test func secondHoldElapsedIsNoop() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    _ = r.triggerDown()
    #expect(r.holdElapsed() == .pttStart)
    #expect(r.holdElapsed() == .none)
}

@Test func reentrantTriggerDownIsIgnoredWhileTracking() {
    var r = ModifierGestureRecognizer(trigger: .rightCommand)
    #expect(r.triggerDown() == .startHoldTimer)
    #expect(r.triggerDown() == .none)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ModifierGestureRecognizerTests`
Expected: FAIL (compile error: type not found).

- [ ] **Step 3: Implement the recognizer**

`ModifierGestureRecognizer.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ModifierGestureRecognizerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore Packages/AudioPipeline/Tests/DictationCoreTests
git commit -m "feat(dictation): add ModifierGestureRecognizer (tap/hold + solo guard)"
```

---

## Task 4: `DictationStateMachine`

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/DictationStateMachine.swift`
- Create: `Packages/AudioPipeline/Tests/DictationCoreTests/DictationStateMachineTests.swift`

- [ ] **Step 1: Write the failing tests**

`DictationStateMachineTests.swift`:

```swift
import Testing
@testable import DictationCore

@Test func toggleLoopThroughInsert() {
    var m = DictationStateMachine()
    #expect(m.startOrToggle() == .beginCapture)
    #expect(m.phase == .listening)
    #expect(m.startOrToggle() == .endCaptureAndTranscribe)
    #expect(m.phase == .transcribing)
    #expect(m.transcriptReady("hello world") == .insert("hello world"))
    #expect(m.phase == .inserting)
    #expect(m.inserted() == .none)
    #expect(m.phase == .idle)
}

@Test func pttUsesReleaseToStop() {
    var m = DictationStateMachine()
    #expect(m.startOrToggle() == .beginCapture)     // pttStart routes here
    #expect(m.release() == .endCaptureAndTranscribe)
    #expect(m.phase == .transcribing)
}

@Test func triggerDuringTranscribeIsIgnored() {
    var m = DictationStateMachine()
    _ = m.startOrToggle()
    _ = m.startOrToggle()                            // now .transcribing
    #expect(m.startOrToggle() == .none)
    #expect(m.phase == .transcribing)
}

@Test func emptyTranscriptReturnsToIdle() {
    var m = DictationStateMachine()
    _ = m.startOrToggle(); _ = m.startOrToggle()
    #expect(m.transcriptReady("   \n ") == .showEmpty)
    #expect(m.phase == .idle)
}

@Test func failureFromTranscribingShowsErrorAndResets() {
    var m = DictationStateMachine()
    _ = m.startOrToggle(); _ = m.startOrToggle()
    #expect(m.failed("boom") == .showError("boom"))
    #expect(m.phase == .idle)
}

@Test func releaseWhenIdleIsNoop() {
    var m = DictationStateMachine()
    #expect(m.release() == .none)
    #expect(m.phase == .idle)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationStateMachineTests`
Expected: FAIL (type not found).

- [ ] **Step 3: Implement the state machine**

`DictationStateMachine.swift`:

```swift
/// Drives one dictation capture from trigger to insertion. Pure; the
/// coordinator performs the returned `Action`s.
public struct DictationStateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case inserting
    }

    public enum Action: Equatable, Sendable {
        case none
        case beginCapture
        case endCaptureAndTranscribe
        case insert(String)
        case showError(String)
        case showEmpty
    }

    public private(set) var phase: Phase = .idle
    public init() {}

    /// Tap toggle or PTT press. Starts capture when idle, otherwise stops.
    public mutating func startOrToggle() -> Action {
        switch phase {
        case .idle:
            phase = .listening
            return .beginCapture
        case .listening:
            phase = .transcribing
            return .endCaptureAndTranscribe
        case .transcribing, .inserting:
            return .none
        }
    }

    /// PTT release. Stops capture only if still listening.
    public mutating func release() -> Action {
        switch phase {
        case .listening:
            phase = .transcribing
            return .endCaptureAndTranscribe
        default:
            return .none
        }
    }

    public mutating func transcriptReady(_ text: String) -> Action {
        guard phase == .transcribing else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            phase = .idle
            return .showEmpty
        }
        phase = .inserting
        return .insert(text)
    }

    public mutating func failed(_ message: String) -> Action {
        guard phase == .transcribing || phase == .inserting else { return .none }
        phase = .idle
        return .showError(message)
    }

    public mutating func inserted() -> Action {
        guard phase == .inserting else { return .none }
        phase = .idle
        return .none
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationStateMachineTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore Packages/AudioPipeline/Tests/DictationCoreTests
git commit -m "feat(dictation): add DictationStateMachine"
```

---

## Task 5: `DictationSettings` + `DictationTranscriber` protocol

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift`
- Create: `Packages/AudioPipeline/Sources/DictationCore/DictationTranscriber.swift`
- Create: `Packages/AudioPipeline/Tests/DictationCoreTests/DictationSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

`DictationSettingsTests.swift`:

```swift
import Testing
@testable import DictationCore

@Test func defaultsAreConservative() {
    let d = DictationSettings.default
    #expect(d.enabled == false)
    #expect(d.trigger == .rightCommand)
    #expect(d.holdThresholdMs == 250)
    #expect(d.providerID == nil)
    #expect(d.model == "whisper-large-v3-turbo")
    #expect(d.insertMode == .autoInsert)
    #expect(d.showOverlay == false)
    #expect(d.keepAudio == false)
}

@Test func roundTripsThroughJSON() throws {
    var d = DictationSettings.default
    d.enabled = true
    d.trigger = .leftCommand
    let data = try JSONEncoder().encode(d)
    #expect(try JSONDecoder().decode(DictationSettings.self, from: data) == d)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettingsTests`
Expected: FAIL (type not found).

- [ ] **Step 3: Implement both types**

`DictationSettings.swift`:

```swift
import Foundation

/// All persisted dictation preferences. Stored by `AppSettings` as one JSON
/// blob (see Task 6).
public struct DictationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var trigger: TriggerSide
    public var holdThresholdMs: Int
    public var providerID: UUID?
    public var model: String
    public var insertMode: InsertMode
    public var showOverlay: Bool
    public var keepAudio: Bool

    public init(
        enabled: Bool = false,
        trigger: TriggerSide = .rightCommand,
        holdThresholdMs: Int = 250,
        providerID: UUID? = nil,
        model: String = "whisper-large-v3-turbo",
        insertMode: InsertMode = .autoInsert,
        showOverlay: Bool = false,
        keepAudio: Bool = false
    ) {
        self.enabled = enabled
        self.trigger = trigger
        self.holdThresholdMs = holdThresholdMs
        self.providerID = providerID
        self.model = model
        self.insertMode = insertMode
        self.showOverlay = showOverlay
        self.keepAudio = keepAudio
    }

    public static let `default` = DictationSettings()
}
```

`DictationTranscriber.swift`:

```swift
import Foundation

/// Streaming-ready seam. Batch implementations ignore `onPartial` and call
/// `onFinal` exactly once. A future websocket/MLX engine emits interim text
/// via `onPartial`.
public protocol DictationTranscriber: Sendable {
    func transcribe(
        audioFile: URL,
        onPartial: @Sendable (String) -> Void,
        onFinal: @Sendable (String) -> Void
    ) async throws
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettingsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore Packages/AudioPipeline/Tests/DictationCoreTests
git commit -m "feat(dictation): add DictationSettings and DictationTranscriber protocol"
```

---

## Task 6: Persist `dictation` in `AppSettings`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`
- Create: `Packages/AudioPipeline/Tests/AppSettingsTests/DictationSettingsPersistenceTests.swift`

- [ ] **Step 1: Write the failing test**

`DictationSettingsPersistenceTests.swift`:

```swift
import Testing
import Foundation
import DictationCore
@testable import AppSettings

@Test func dictationDefaultsWhenAbsent() {
    let defaults = UserDefaults(suiteName: "dictation-test-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.dictation == .default)
}

@Test func dictationRoundTripsThroughDefaults() {
    let suite = "dictation-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let settings = AppSettings(defaults: defaults)
    var d = DictationSettings.default
    d.enabled = true
    d.model = "whisper-large-v3"
    settings.dictation = d

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.dictation.enabled == true)
    #expect(reloaded.dictation.model == "whisper-large-v3")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettingsPersistenceTests`
Expected: FAIL (no `dictation` member).

- [ ] **Step 3: Add the property to `AppSettings`**

Add to the top of `AppSettings.swift`:

```swift
import DictationCore
```

Add the stored property alongside the other `public var`s (e.g. after `suggestRecordingWhenMicInUse`):

```swift
    public var dictation: DictationSettings {
        didSet { persistDictation() }
    }
```

In `init(defaults:)`, after the existing reads, decode the blob (mirrors the `object(forKey:) != nil` guard style used for `keepOriginalCAF`):

```swift
        if let data = defaults.data(forKey: Keys.dictation),
           let decoded = try? JSONDecoder().decode(DictationSettings.self, from: data) {
            dictation = decoded
        } else {
            dictation = .default
        }
```

Add the persistence helper as a method on the class:

```swift
    private func persistDictation() {
        if let data = try? JSONEncoder().encode(dictation) {
            defaults.set(data, forKey: Keys.dictation)
        }
    }
```

Add the key to the `Keys` enum:

```swift
        static let dictation = "dictation"
```

> Note: `didSet` does not fire for the initial assignment inside `init`, so the decode path does not re-persist — correct.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettingsPersistenceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the full SPM suite (no regressions)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (all targets).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings Packages/AudioPipeline/Tests/AppSettingsTests
git commit -m "feat(dictation): persist DictationSettings in AppSettings"
```

---

## Task 7: `DictationTempStore` (temp-dir naming + sweep)

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/DictationTempStore.swift`
- Create: `Packages/AudioPipeline/Tests/DictationCoreTests/DictationTempStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`DictationTempStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import DictationCore

private func tmpDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dtest-\(UUID().uuidString)", isDirectory: true)
}

@Test func newCaptureURLIsUniqueWavInDirectory() {
    let store = DictationTempStore(directory: tmpDir())
    let a = store.newCaptureURL()
    let b = store.newCaptureURL()
    #expect(a != b)
    #expect(a.pathExtension == "wav")
    #expect(a.deletingLastPathComponent() == store.directory)
}

@Test func sweepRemovesOrphans() throws {
    let store = DictationTempStore(directory: tmpDir())
    let url = store.newCaptureURL()
    try Data("x".utf8).write(to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    store.sweep()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func deleteRemovesOne() throws {
    let store = DictationTempStore(directory: tmpDir())
    let url = store.newCaptureURL()
    try Data("x".utf8).write(to: url)
    store.delete(url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationTempStoreTests`
Expected: FAIL (type not found).

- [ ] **Step 3: Implement the store**

`DictationTempStore.swift`:

```swift
import Foundation

/// Owns the ephemeral capture directory. Unique filenames so an in-flight
/// upload is never clobbered; `sweep()` (called on launch) reclaims orphans.
public final class DictationTempStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dictation", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    public func newCaptureURL() -> URL {
        directory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
    }

    public func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func sweep() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationTempStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore Packages/AudioPipeline/Tests/DictationCoreTests
git commit -m "feat(dictation): add DictationTempStore (unique names + sweep)"
```

---

## Task 8: `DictationRecorder` — 16 kHz mono WAV capture

No SPM unit test (needs a real input device). Verified by app build + the manual checklist. Lives in `RecordingCore` (audio-thread code belongs with the other capture code and inherits its `nonisolated` isolation + the `@Sendable` tap rule — see the `feedback_mainactor_closure_sendable_audio` memory).

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/DictationWAVWriter.swift`
- Create: `Packages/AudioPipeline/Sources/RecordingCore/DictationRecorder.swift`

- [ ] **Step 1: Implement the Sendable writer (converts + writes on a private queue)**

`DictationWAVWriter.swift`:

```swift
import AVFoundation

/// Converts incoming hardware-format buffers to 16 kHz mono Int16 and writes
/// them to a WAV file, on a private serial queue. `@unchecked Sendable` so the
/// audio-thread tap can capture it (mirrors `AudioFileWriter`).
final class DictationWAVWriter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "work.miklos.amanuensis.dictation.writer", qos: .userInitiated)
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onLevel: (@Sendable (Float) -> Void)?
    private var frames: Int64 = 0

    init(url: URL, inputFormat: AVAudioFormat,
         onLevel: (@Sendable (Float) -> Void)?) throws {
        self.onLevel = onLevel
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000,
            channels: 1, interleaved: true) else {
            throw DictationRecorderError.formatUnavailable
        }
        self.outputFormat = out
        guard let conv = AVAudioConverter(from: inputFormat, to: out) else {
            throw DictationRecorderError.formatUnavailable
        }
        self.converter = conv
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            onLevel?(Self.rms(buffer))
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
            guard let out = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, inStatus in
                if fed { inStatus.pointee = .noDataNow; return nil }
                fed = true
                inStatus.pointee = .haveData
                return buffer
            }
            if status == .haveData, err == nil {
                try? file.write(from: out)
                frames += Int64(out.frameLength)
            }
        }
    }

    func close() async -> Int64 {
        await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: frames) }
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[0][i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }
}
```

> Gotcha to verify: `floatChannelData` is non-nil only when the engine's input format is Float32 (the common case for `AVAudioEngine`). If a device delivers Int16, `rms` returns 0 (level meter inert) but capture still works — acceptable for v1.

- [ ] **Step 2: Implement the recorder (owns the engine; tap captures the writer)**

`DictationRecorder.swift`:

```swift
import AVFoundation

public enum DictationRecorderError: Error, Sendable {
    case noInput
    case formatUnavailable
}

/// Mic-only capture straight to a 16 kHz mono WAV. No post-stop transcode.
public final class DictationRecorder {
    private let engine = AVAudioEngine()
    private let writer: DictationWAVWriter

    public init(url: URL, onLevel: (@Sendable (Float) -> Void)? = nil) throws {
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw DictationRecorderError.noInput
        }
        self.writer = try DictationWAVWriter(
            url: url, inputFormat: input, onLevel: onLevel)
    }

    public func start() throws {
        let input = engine.inputNode.inputFormat(forBus: 0)
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 4_096, format: input
        ) { @Sendable [writer] buffer, _ in
            // Deep-copy: the tap buffer is framework-owned and reused after this
            // callback returns; the writer reads it later on its own queue.
            if let copy = buffer.deepCopy() { writer.enqueue(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops capture, flushes the writer, returns frames written.
    public func stop() async -> Int64 {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return await writer.close()
    }
}
```

- [ ] **Step 3: Build the SPM package**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: builds with no errors. If strict-concurrency flags the tap closure, confirm `DictationWAVWriter` is `@unchecked Sendable` and captured as `[writer]` (not `self`).

- [ ] **Step 4: Run the full SPM suite (no regressions)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/DictationWAVWriter.swift Packages/AudioPipeline/Sources/RecordingCore/DictationRecorder.swift
git commit -m "feat(dictation): add 16kHz mono WAV DictationRecorder"
```

---

## Task 9: `BatchTranscriber` (app-side Jobs adapter)

**Files:**
- Create: `Amanuensis/Dictation/BatchTranscriber.swift`
- Test: `AmanuensisTests/BatchTranscriberTests.swift`

> The app target must link `DictationCore`. Do this once now: in Xcode, select the **Amanuensis** target → **Frameworks, Libraries, and Embedded Content** → **+** → add the **DictationCore** library product from the local `AudioPipeline` package. (The package is already a local dependency; this only adds the new product.) Commit the resulting `project.pbxproj` change with this task.

- [ ] **Step 1: Write the implementation**

`Amanuensis/Dictation/BatchTranscriber.swift`:

```swift
import Foundation
import DictationCore
import AudioPipelineJobs

/// Batch `DictationTranscriber` over an existing `AudioJobSending` handler.
/// Built per-capture with an already-resolved provider/shape/model.
struct BatchTranscriber: DictationTranscriber {
    let job: Job
    let provider: Provider
    let shape: JobShape
    let keychain: any KeychainProviding
    var handlers: [JobShape: any AudioJobSending] = JobRunner.defaultHandlers

    func transcribe(
        audioFile: URL,
        onPartial: @Sendable (String) -> Void,
        onFinal: @Sendable (String) -> Void
    ) async throws {
        guard let handler = handlers[shape] else {
            throw DictationError.unsupportedShape
        }
        let key = try await keychain.get(account: provider.apiKeyRef.account)
        let text = try await handler.send(
            job: job, provider: provider, audioURL: audioFile, apiKey: key)
        onFinal(text)
    }
}
```

- [ ] **Step 2: Write the failing test (stub handler + fake keychain — no network/device)**

`AmanuensisTests/BatchTranscriberTests.swift`:

```swift
import XCTest
import DictationCore
import AudioPipelineJobs
@testable import Amanuensis

private struct StubHandler: AudioJobSending {
    let reply: String
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        reply
    }
}

private struct FakeKeychain: KeychainProviding {
    func get(account: String) async throws -> String { "fake-key" }
}

final class BatchTranscriberTests: XCTestCase {
    func testReturnsHandlerTextAsFinal() async throws {
        let provider = Provider(
            name: "Groq", presetID: "groq-whisper",
            baseURL: "https://api.groq.com/openai",
            apiKeyRef: KeychainRef(account: "groq"))
        let job = Job(
            name: "Dictation", providerID: provider.id,
            model: "whisper-large-v3-turbo", fields: [:], outputExt: "txt")
        let sut = BatchTranscriber(
            job: job, provider: provider, shape: .transcriptionMultipart,
            keychain: FakeKeychain(),
            handlers: [.transcriptionMultipart: StubHandler(reply: "hello there")])

        var final: String?
        try await sut.transcribe(
            audioFile: URL(fileURLWithPath: "/dev/null"),
            onPartial: { _ in }, onFinal: { final = $0 })
        XCTAssertEqual(final, "hello there")
    }
}
```

- [ ] **Step 3: Build + run the app-hosted test via the xcode-build skill**

Use the **xcode-build** skill (daemon) to run:
`./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' test`
Expected: `BatchTranscriberTests.testReturnsHandlerTextAsFinal` PASSES. (If the app doesn't yet link `DictationCore`, the import fails — complete the linking note above first.)

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/Dictation/BatchTranscriber.swift AmanuensisTests/BatchTranscriberTests.swift Amanuensis.xcodeproj/project.pbxproj
git commit -m "feat(dictation): add BatchTranscriber over AudioJobSending"
```

---

## Task 10: `TextInserter` (pasteboard + synthetic ⌘V)

No automated test (posts real events / needs Post Event TCC). Build + manual.

**Files:**
- Create: `Amanuensis/Dictation/TextInserter.swift`

- [ ] **Step 1: Implement**

`Amanuensis/Dictation/TextInserter.swift`:

```swift
import AppKit
import CoreGraphics
import DictationCore

/// Inserts text at the cursor by placing it on the pasteboard and posting a
/// synthetic ⌘V (Post Event access — App-Sandbox-compatible). Falls back to
/// leaving text on the clipboard when access is absent or mode is clipboardOnly.
@MainActor
final class TextInserter {
    enum Outcome: Equatable { case inserted, clipboardFallback }

    static func hasPostEventAccess() -> Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }

    func insert(_ text: String, mode: InsertMode) -> Outcome {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard mode == .autoInsert, Self.hasPostEventAccess() else {
            return .clipboardFallback
        }
        postCommandV()
        if let saved {
            // Restore after the paste has been delivered to the target app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
        return .inserted
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9   // ANSI 'v'
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
```

- [ ] **Step 2: Build the app via the xcode-build skill**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: builds clean.

- [ ] **Step 3: Manual verification (deferred to Task 12 once wired)**

Recorded in the Task 12 manual checklist (insert into TextEdit; clipboard restored; clipboard-only mode leaves text + no paste).

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/Dictation/TextInserter.swift
git commit -m "feat(dictation): add TextInserter (synthetic Cmd-V + clipboard fallback)"
```

---

## Task 11: `HotkeyTapMonitor` (`CGEventTap(.listenOnly)`)

No automated test (needs Input Monitoring TCC + real key events). Build + manual.

**Files:**
- Create: `Amanuensis/Dictation/HotkeyTapMonitor.swift`

- [ ] **Step 1: Implement**

`Amanuensis/Dictation/HotkeyTapMonitor.swift`:

```swift
import AppKit
import CoreGraphics
import DictationCore

/// Observes (never consumes) global key events via a listen-only CGEvent tap,
/// emitting trigger/foreign events. Needs Input Monitoring (sandbox-OK).
/// Must be started on the main thread (the tap source is added to the main
/// run loop, so the C callback runs main-isolated).
@MainActor
final class HotkeyTapMonitor {
    enum Event: Equatable { case triggerDown, triggerUp, foreignInput }

    // Device-dependent modifier bits (IOKit NX_DEVICE*CMDKEYMASK).
    private static let leftCmdBit: UInt64 = 0x0000_0008
    private static let rightCmdBit: UInt64 = 0x0000_0010

    private var trigger: TriggerSide
    private let onEvent: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(trigger: TriggerSide, onEvent: @escaping (Event) -> Void) {
        self.trigger = trigger
        self.onEvent = onEvent
    }

    static func hasInputMonitoringAccess() -> Bool { CGPreflightListenEventAccess() }

    @discardableResult
    static func requestInputMonitoringAccess() -> Bool { CGRequestListenEventAccess() }

    func setTrigger(_ t: TriggerSide) { trigger = t }

    func start() {
        guard tap == nil else { return }
        let mask = (UInt64(1) << CGEventType.flagsChanged.rawValue)
                 | (UInt64(1) << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyTapMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            onEvent(.foreignInput)
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == trigger.keyCode {
                let bit = trigger == .leftCommand ? Self.leftCmdBit : Self.rightCmdBit
                onEvent((event.flags.rawValue & bit) != 0 ? .triggerDown : .triggerUp)
            } else {
                onEvent(.foreignInput)
            }
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Build the app via the xcode-build skill**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Amanuensis/Dictation/HotkeyTapMonitor.swift
git commit -m "feat(dictation): add HotkeyTapMonitor (listen-only CGEventTap)"
```

---

## Task 12: `DictationCoordinator` + `AppCoordinator` wiring

The brain. Owns the recognizer, state machine, monitor, inserter, temp store, recorder, and overlay; resolves the transcriber per capture.

**Files:**
- Create: `Amanuensis/Dictation/DictationCoordinator.swift`
- Modify: `Amanuensis/AppCoordinator.swift`

- [ ] **Step 1: Implement `DictationCoordinator`**

`Amanuensis/Dictation/DictationCoordinator.swift`:

```swift
import Foundation
import AppKit
import DictationCore
import RecordingCore
import AudioPipelineJobs
import AppSettings

/// Wires hotkey gestures → dictation state machine → capture/transcribe/insert.
/// Hung off AppCoordinator; mirrors the mic-cue apply(_:) pattern.
@MainActor
@Observable
final class DictationCoordinator {
    private(set) var phase: DictationStateMachine.Phase = .idle
    private(set) var level: Float = 0

    private let settings: AppSettings
    private let keychain: any KeychainProviding
    private let providerLookup: (UUID) -> Provider?
    private let presetLookup: (String) -> Preset?
    private let log: (String) -> Void

    private var recognizer: ModifierGestureRecognizer
    private var machine = DictationStateMachine()
    private let inserter = TextInserter()
    private let tempStore = DictationTempStore()
    private let overlay = DictationOverlayController()
    private var monitor: HotkeyTapMonitor?

    private var recorder: DictationRecorder?
    private var captureURL: URL?
    private var holdTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    init(settings: AppSettings,
         keychain: any KeychainProviding,
         providerLookup: @escaping (UUID) -> Provider?,
         presetLookup: @escaping (String) -> Preset?,
         log: @escaping (String) -> Void) {
        self.settings = settings
        self.keychain = keychain
        self.providerLookup = providerLookup
        self.presetLookup = presetLookup
        self.log = log
        self.recognizer = ModifierGestureRecognizer(trigger: settings.dictation.trigger)
        tempStore.sweep()                       // reclaim crash orphans on launch
        if settings.dictation.enabled { startMonitor() }
    }

    // MARK: Settings

    /// Called from Settings when `enabled` or `trigger` changes.
    func settingsChanged() {
        recognizer.trigger = settings.dictation.trigger
        monitor?.setTrigger(settings.dictation.trigger)
        if settings.dictation.enabled {
            startMonitor()
        } else {
            stopMonitor()
        }
    }

    private func startMonitor() {
        if monitor == nil {
            monitor = HotkeyTapMonitor(trigger: settings.dictation.trigger) { [weak self] event in
                self?.handle(event)
            }
        }
        monitor?.start()
    }

    private func stopMonitor() {
        holdTask?.cancel(); holdTask = nil
        monitor?.stop()
    }

    // MARK: Event pipeline

    private func handle(_ event: HotkeyTapMonitor.Event) {
        switch event {
        case .triggerDown: applyGesture(recognizer.triggerDown())
        case .triggerUp:   applyGesture(recognizer.triggerUp())
        case .foreignInput: applyGesture(recognizer.foreignInput())
        }
    }

    private func applyGesture(_ gesture: ModifierGestureRecognizer.Gesture) {
        switch gesture {
        case .none:
            break
        case .startHoldTimer:
            holdTask?.cancel()
            let ms = settings.dictation.holdThresholdMs
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                guard let self, !Task.isCancelled else { return }
                self.applyGesture(self.recognizer.holdElapsed())
            }
        case .toggle, .pttStart:
            applyAction(machine.startOrToggle())
        case .pttEnd:
            applyAction(machine.release())
        case .cancel:
            holdTask?.cancel(); holdTask = nil
        }
    }

    private func applyAction(_ action: DictationStateMachine.Action) {
        switch action {
        case .none:
            break
        case .beginCapture:
            beginCapture()
        case .endCaptureAndTranscribe:
            endCaptureAndTranscribe()
        case .insert(let text):
            let outcome = inserter.insert(text, mode: settings.dictation.insertMode)
            if outcome == .clipboardFallback {
                overlay.flash("Copied — press ⌘V")
            }
            applyAction(machine.inserted())
        case .showError(let message):
            log("Dictation failed: \(message)")
            overlay.flash("Dictation failed")
        case .showEmpty:
            overlay.flash("Nothing heard")
        }
        phase = machine.phase
        overlay.update(phase: phase, enabled: settings.dictation.showOverlay)
    }

    // MARK: Effects

    private func beginCapture() {
        // Guard: a provider must be configured.
        guard resolveTranscriberInputs() != nil else {
            log("Dictation: no provider configured")
            overlay.flash("Set a dictation provider in Settings")
            _ = machine.failed("no provider")   // returns to idle
            phase = machine.phase
            return
        }
        let url = tempStore.newCaptureURL()
        captureURL = url
        do {
            let rec = try DictationRecorder(url: url) { [weak self] lvl in
                Task { @MainActor in self?.level = lvl }
            }
            try rec.start()
            recorder = rec
        } catch {
            log("Dictation capture failed: \(error.localizedDescription)")
            overlay.flash("Mic unavailable")
            _ = machine.failed(error.localizedDescription)
            phase = machine.phase
        }
    }

    private func endCaptureAndTranscribe() {
        guard let recorder, let url = captureURL,
              let inputs = resolveTranscriberInputs() else { return }
        self.recorder = nil
        let transcriber = BatchTranscriber(
            job: inputs.job, provider: inputs.provider,
            shape: inputs.shape, keychain: keychain)
        transcribeTask = Task { [weak self] in
            _ = await recorder.stop()
            defer { self?.tempStore.delete(url) }
            do {
                var result = ""
                try await transcriber.transcribe(
                    audioFile: url, onPartial: { _ in }, onFinal: { result = $0 })
                self?.applyAction(self?.machine.transcriptReady(result) ?? .none)
            } catch {
                self?.applyAction(self?.machine.failed(error.localizedDescription) ?? .none)
            }
        }
    }

    private struct TranscriberInputs { let job: Job; let provider: Provider; let shape: JobShape }

    private func resolveTranscriberInputs() -> TranscriberInputs? {
        guard let pid = settings.dictation.providerID,
              let provider = providerLookup(pid),
              let preset = presetLookup(provider.presetID) else { return nil }
        let job = Job(
            name: "Dictation", providerID: provider.id,
            model: settings.dictation.model, fields: preset.defaults, outputExt: "txt")
        return TranscriberInputs(job: job, provider: provider, shape: preset.shape)
    }
}
```

> `DictationOverlayController` (with `flash(_:)`, `update(phase:enabled:)`) is created in Task 15. To build this task before Task 15, add a minimal stub of that controller first, or implement Task 15 immediately after Step 1 here and build them together. The plan builds the app at Step 3 below, so implement Task 15's controller before that build (the two are co-dependent UI glue).

- [ ] **Step 2: Wire it into `AppCoordinator`**

In `Amanuensis/AppCoordinator.swift`, add a stored property near the other subsystems:

```swift
    let dictation: DictationCoordinator
```

Add a UI convenience accessor (used by the Settings picker in Task 14):

```swift
    var allProviders: [Provider] { providers.providers }
```

At the **end** of `init()` (after the logs store is set), construct it:

```swift
        self.dictation = DictationCoordinator(
            settings: settings,
            keychain: keychain,
            providerLookup: { [providers] id in providers.provider(id: id) },
            presetLookup: { [presets] id in presets.preset(id: id) },
            log: { [logs] message in logs.log(.error, message, category: .recording) }
        )
```

> `providers`, `presets`, `keychain`, `logs`, and `settings` are all assigned earlier in `init`, so they are available here. `KeychainStore` already conforms to `KeychainProviding`.

Add the import at the top if not present:

```swift
import DictationCore
```

- [ ] **Step 3: Build the app via the xcode-build skill** (after Task 15's controller exists)

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/Dictation/DictationCoordinator.swift Amanuensis/AppCoordinator.swift
git commit -m "feat(dictation): add DictationCoordinator and wire into AppCoordinator"
```

---

## Task 13: Animated menu-bar icon

**Files:**
- Create: `Amanuensis/UI/DictationMenuBarLabel.swift`
- Modify: `Amanuensis/AmanuensisApp.swift`

- [ ] **Step 1: Implement the label view**

`Amanuensis/UI/DictationMenuBarLabel.swift`:

```swift
import SwiftUI

/// State-driven menu-bar icon: idle, meeting-recording, or dictating (animated).
struct DictationMenuBarLabel: View {
    let coordinator: AppCoordinator

    var body: some View {
        if coordinator.dictation.phase != .idle {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else if coordinator.isRecording {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
        } else {
            Image(systemName: "waveform.circle")
                .symbolRenderingMode(.hierarchical)
        }
    }
}
```

- [ ] **Step 2: Use it as the `MenuBarExtra` label**

In `Amanuensis/AmanuensisApp.swift`, replace the existing `label:` closure:

```swift
        } label: {
            Image(systemName: coordinator.isRecording
                  ? "record.circle.fill"
                  : "waveform.circle")
                .symbolRenderingMode(.hierarchical)
        }
```

with:

```swift
        } label: {
            DictationMenuBarLabel(coordinator: coordinator)
        }
```

- [ ] **Step 3: Build via the xcode-build skill**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: builds clean.

- [ ] **Step 4: Manual check**

Launch the app; while dictating (after Task 14 wiring), the menu-bar icon shows an animated `waveform`. If `.menu`-style MenuBarExtra renders it static, note for the deferred `NSStatusItem` escalation (spec D12) — do not block on it.

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/UI/DictationMenuBarLabel.swift Amanuensis/AmanuensisApp.swift
git commit -m "feat(dictation): animated menu-bar dictation icon"
```

---

## Task 14: Settings — Dictation section + permission rows

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift`

- [ ] **Step 1: Add the section**

In `SettingsView.swift`, add a new `Section` inside the `Form` (after the `Meetings` section). It binds to `settings.dictation` sub-fields and calls `coordinator.dictation.settingsChanged()` when `enabled`/`trigger` change:

```swift
            Section("Dictation") {
                Toggle("Enable dictation", isOn: $settings.dictation.enabled)
                    .onChange(of: settings.dictation.enabled) { _, _ in
                        coordinator.dictation.settingsChanged()
                    }

                Picker("Trigger key", selection: $settings.dictation.trigger) {
                    Text("Right ⌘").tag(TriggerSide.rightCommand)
                    Text("Left ⌘").tag(TriggerSide.leftCommand)
                }
                .onChange(of: settings.dictation.trigger) { _, _ in
                    coordinator.dictation.settingsChanged()
                }

                LabeledContent("Hold threshold") {
                    HStack {
                        Slider(value: holdThresholdBinding, in: 150...600, step: 50)
                        Text("\(settings.dictation.holdThresholdMs) ms")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Picker("Provider", selection: $settings.dictation.providerID) {
                    Text("None").tag(UUID?.none)
                    ForEach(coordinator.allProviders) { provider in
                        Text(provider.name).tag(UUID?.some(provider.id))
                    }
                }

                TextField("Model", text: $settings.dictation.model)

                Picker("On finish", selection: $settings.dictation.insertMode) {
                    Text("Insert at cursor").tag(InsertMode.autoInsert)
                    Text("Copy to clipboard").tag(InsertMode.clipboardOnly)
                }

                Toggle("Show overlay while dictating", isOn: $settings.dictation.showOverlay)

                permissionRow(
                    title: "Input Monitoring (hotkey)",
                    granted: inputMonitoringGranted,
                    grant: {
                        HotkeyTapMonitor.requestInputMonitoringAccess()
                        refreshPermissions()
                    })
                permissionRow(
                    title: "Accessibility · post events (auto-insert)",
                    granted: postEventGranted,
                    grant: {
                        TextInserter.requestPostEventAccess()
                        refreshPermissions()
                    })
            }
```

- [ ] **Step 2: Add the supporting state, binding, and helpers**

Add stored state to `SettingsView` (near the existing properties):

```swift
    @State private var inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
    @State private var postEventGranted = TextInserter.hasPostEventAccess()
```

Add these helpers inside `SettingsView` (after `body`):

```swift
    private var holdThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.dictation.holdThresholdMs) },
            set: { settings.dictation.holdThresholdMs = Int($0) })
    }

    private func refreshPermissions() {
        inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
        postEventGranted = TextInserter.hasPostEventAccess()
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Grant…", action: grant)
            }
        }
    }
```

Add the import at the top:

```swift
import DictationCore
```

- [ ] **Step 3: Grow the window frame for the larger form**

Change the existing:

```swift
        .frame(width: 480, height: 360)
```

to:

```swift
        .frame(width: 480, height: 640)
```

- [ ] **Step 4: Build via the xcode-build skill**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/UI/SettingsView.swift
git commit -m "feat(dictation): Settings section + permission rows"
```

---

## Task 15: Overlay panel

Implement this **before** building Task 12 (the coordinator references it). Bottom-center non-activating panel; mirrors `MicCueController`.

**Files:**
- Create: `Amanuensis/UI/DictationOverlayController.swift`
- Create: `Amanuensis/UI/DictationOverlayView.swift`

- [ ] **Step 1: Implement the view**

`Amanuensis/UI/DictationOverlayView.swift`:

```swift
import SwiftUI
import DictationCore

struct DictationOverlayView: View {
    let phase: DictationStateMachine.Phase
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .listening:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Listening…")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            case .inserting, .idle:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Inserted")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
```

- [ ] **Step 2: Implement the controller**

`Amanuensis/UI/DictationOverlayController.swift`:

```swift
import AppKit
import SwiftUI
import DictationCore

/// Optional bottom-center HUD. Non-activating panel; mirrors MicCueController.
@MainActor
final class DictationOverlayController {
    private var panel: NSPanel?
    private var phase: DictationStateMachine.Phase = .idle
    private var level: Float = 0
    private var flashTask: Task<Void, Never>?

    /// Show/hide based on phase + the user's overlay preference.
    func update(phase: DictationStateMachine.Phase, enabled: Bool) {
        self.phase = phase
        guard enabled, phase != .idle else { hide(); return }
        render()
    }

    /// Brief transient message (clipboard fallback / errors / empty).
    func flash(_ message: String) {
        showText(message)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            if self.phase == .idle { self.hide() }
        }
    }

    private func render() {
        present(AnyView(DictationOverlayView(phase: phase, level: level)))
    }

    private func showText(_ message: String) {
        present(AnyView(
            Text(message)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())))
    }

    private func present(_ root: AnyView) {
        let hosting = NSHostingView(rootView: root)
        hosting.layout()
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            panel = p
        }
        guard let panel else { return }
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 80))
    }
}
```

- [ ] **Step 3: Build via the xcode-build skill** (together with Task 12)

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/DictationOverlayController.swift Amanuensis/UI/DictationOverlayView.swift
git commit -m "feat(dictation): bottom-center dictation overlay"
```

---

## Task 16: End-to-end verification + permissions audit

No code unless a gap surfaces. Confirms the feature works and that no new entitlement is needed.

- [ ] **Step 1: Full SPM suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all PASS.

- [ ] **Step 2: App build + app-hosted tests via the xcode-build skill**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' test`
Expected: build + `BatchTranscriberTests` PASS.

- [ ] **Step 3: Manual checklist (run the built app)**

Configure a Groq provider + select it in Settings → Dictation; grant Input Monitoring and Post Event when prompted.
- [ ] Tap right ⌘ once in TextEdit → records; tap again → transcript pastes at the cursor.
- [ ] Hold right ⌘, speak, release → transcript pastes (PTT).
- [ ] ⌘C / ⌘V / ⌘-tab do **not** trigger dictation (solo guard).
- [ ] Left ⌘ alone does nothing (only right ⌘ is bound).
- [ ] Clipboard contents are restored after an auto-insert.
- [ ] "Copy to clipboard" mode: text lands on clipboard, no auto-paste, cue shown.
- [ ] Revoke Post Event access → auto-insert degrades to clipboard + cue, hotkey still works.
- [ ] Enable the overlay → bottom-center HUD shows listening/transcribing/inserted.
- [ ] Menu-bar icon animates while dictating.
- [ ] Quit mid-capture, relaunch → `Dictation/` temp dir is empty (startup sweep).

- [ ] **Step 4: Entitlements audit**

Confirm `Amanuensis.entitlements` is unchanged — Input Monitoring and Post Event are runtime TCC grants, not entitlements, and microphone is already present. If the live app cannot register the tap or post events under the sandbox, capture the exact console error and revisit (spec Permissions section). Do **not** disable the sandbox without re-confirming with the spec owner.

- [ ] **Step 5: Final commit (if any audit fixes)**

```bash
git add -A
git commit -m "test(dictation): end-to-end verification and entitlements audit"
```

---

## Self-Review

**Spec coverage (each spec decision → task):**
- D1 hotkey via CGEventTap listen-only → Task 11. D2 L/R via device bits → Task 11 + `TriggerSide` Task 2. D3 tap/hold one trigger → Tasks 3, 12. D4 solo guard → Task 3 (`foreignInput`) + Task 11 (foreign emission). D5 paste via CGEvent post → Task 10. D6 clipboard fallback → Task 10 + Task 12. D7 16 kHz WAV, no post-stop transcode → Task 8. D8 temp dir + unique names + per-session delete + startup sweep → Task 7 + Task 12 (`tempStore.delete`/`sweep`). D9 keepAudio opt-in default off → `DictationSettings` Task 5 (field present; honoring it on capture is out of v1 scope beyond storing the pref — capture currently always deletes; see note). D10 pure core / effectful edges → package vs app split throughout. D11 Groq default, transient Job, any provider → Tasks 5, 9, 12. D12 SF Symbol animation first → Task 13. Streaming/MLX seam → `DictationTranscriber` Task 5. Settings UI → Task 14. Overlay → Task 15.
  - **Gap noted:** D9 `keepAudio` is persisted but not yet acted on (capture always deletes the temp WAV). Honoring `keepAudio` (copying the WAV to a kept location before delete) is a small follow-up; flagged rather than silently dropped. If the spec owner wants it in v1, add a step in Task 12's `endCaptureAndTranscribe` defer: when `settings.dictation.keepAudio`, copy `url` into a non-swept folder before `tempStore.delete(url)`.

**Placeholder scan:** No "TODO/handle errors/similar to" — every code step is complete. The two cross-task UI co-dependencies (Task 12 ↔ Task 15) are called out explicitly with build ordering, not left implicit.

**Type consistency:** `ModifierGestureRecognizer.Gesture` (`startHoldTimer/toggle/pttStart/pttEnd/cancel/none`) is produced in Task 3 and consumed verbatim in Task 12. `DictationStateMachine.Action` cases match between Task 4 and Task 12's `applyAction`. `HotkeyTapMonitor.Event` (`triggerDown/triggerUp/foreignInput`) matches Task 11 ↔ Task 12 `handle`. `TextInserter.Outcome`/`insert(_:mode:)`, `DictationTranscriber.transcribe(audioFile:onPartial:onFinal:)`, `Job(name:providerID:model:fields:outputExt:)`, `KeychainProviding.get(account:)`, `providers.provider(id:)`/`presets.preset(id:)`/`providers.providers` all match the verbatim signatures extracted from the codebase.
