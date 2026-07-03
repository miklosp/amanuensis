# Realtime Streaming ASR — M3 (Production Integration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Graduate the two GO'd streaming spikes into real dictation — pressing the dictation hotkey with a streaming-capable provider selected and "Stream results live" on makes words appear live in the frontmost app, via a `RealtimeSTTProvider` abstraction proven by two adapters (Reson8 + Soniox).

**Architecture:** A new `RealtimeSTTProvider`/`RealtimeSTTSession` seam in `AudioPipelineJobs` (parallel to `DictationTranscriber`, which stays for batch). `DictationStateMachine` gains a `streaming`/`finalizing` mode; `DictationCoordinator` drives a live capture — mic PCM fans to the session while off-thread transcript events bridge onto the MainActor through an `AsyncStream` into the existing `CommitController` + `KeystrokeDiffInserter`. A capability registry keyed on `presetID` gates the toggle. Reson8 adapts its existing client; Soniox is a new Reson8-parallel wire trio.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, `URLSessionWebSocketTask`, Swift Testing (`@Suite`/`@Test`), SPM (`Packages/AudioPipeline`), Xcode app target `Amanuensis`.

## Global Constraints

- Swift 6.2, deployment target macOS 26.3. Strict concurrency; `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- **App target** default actor isolation is `MainActor`. **`AudioPipelineJobs`, `DictationCore`, `RecordingCore`** targets are `nonisolated` by default (see `Package.swift`). Audio-thread closures crossing into these from `@MainActor` types must be explicitly `@Sendable` (they already are on `DictationRecorder`'s `onLevel`/`onChunk`).
- App Sandbox on; `network.client` entitlement already covers WebSockets. No new entitlement.
- **SPM tests:** `swift test --disable-sandbox --package-path Packages/AudioPipeline` (the `--disable-sandbox` flag is required in this environment). Filter a suite with `--filter <SuiteName>`.
- **After SPM tests pass, always rebuild the app target** — a green SPM suite is not proof the app compiles: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`.
- Conventional commits. End every commit message with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- New `.swift` files under `Amanuensis/` are auto-registered (synchronized group) — no pbxproj edits. New files under `Packages/AudioPipeline/Sources/<Target>/` are auto-compiled.

## Phasing

- **Phase A (Tasks 1–7):** Reson8 streaming works end-to-end through the real hotkey/coordinator, with the settings surface. Deliverable after Task 7: a user can stream-dictate with Reson8.
- **Phase B (Tasks 8–12):** Soniox second adapter proves the abstraction generalizes; DEBUG smoke + final rebuild.

---

## Task 1: Streaming seam types (`AudioPipelineJobs`)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/RealtimeSTT.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeClient.swift` (add conformance)
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/RealtimeSTTTests.swift`

**Interfaces:**
- Produces: `TranscriptEvent` (`.partial(String)`/`.final(String)`), `RealtimeSTTSession` (`start()`, `send(_:)`, `finish() async`), `RealtimeSTTProvider` (`makeSession(baseURL:apiKey:language:onEvent:onError:) throws -> RealtimeSTTSession`). `Reson8RealtimeClient: RealtimeSTTSession`.

- [ ] **Step 1: Write the failing test**

```swift
// RealtimeSTTTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct RealtimeSTTSeam {
    /// A minimal conformer proving the protocols are usable and the event type is value-equal.
    final class FakeSession: RealtimeSTTSession, @unchecked Sendable {
        nonisolated(unsafe) var started = false
        nonisolated(unsafe) var sent: [Data] = []
        nonisolated(unsafe) var finished = false
        func start() { started = true }
        func send(_ pcm: Data) { sent.append(pcm) }
        func finish() async { finished = true }
    }

    struct FakeProvider: RealtimeSTTProvider {
        func makeSession(baseURL: String, apiKey: String, language: String,
                         onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
                         onError: @escaping @Sendable (Error) -> Void) throws -> RealtimeSTTSession {
            onEvent(.partial("hi"))
            return FakeSession()
        }
    }

    @Test func eventEquality() {
        #expect(TranscriptEvent.partial("a") == .partial("a"))
        #expect(TranscriptEvent.partial("a") != .final("a"))
    }

    @Test func providerYieldsEventsAndSession() async throws {
        var events: [TranscriptEvent] = []
        let session = try FakeProvider().makeSession(
            baseURL: "https://x", apiKey: "k", language: "en",
            onEvent: { events.append($0) }, onError: { _ in })
        session.start()
        session.send(Data([0, 1]))
        await session.finish()
        #expect(events == [.partial("hi")])
        let fake = session as? FakeSession
        #expect(fake?.started == true)
        #expect(fake?.sent.count == 1)
        #expect(fake?.finished == true)
    }

    @Test func reson8ClientIsARealtimeSession() {
        let url = try! Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev")
        let client = Reson8RealtimeClient(url: url, apiKey: "k",
            onPartial: { _ in }, onFinal: { _ in })
        let session: RealtimeSTTSession = client   // compile-time proof of conformance
        _ = session
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RealtimeSTTSeam`
Expected: FAIL — `cannot find type 'RealtimeSTTSession'` / `TranscriptEvent` in scope.

- [ ] **Step 3: Create the seam types**

```swift
// RealtimeSTT.swift
import Foundation

/// One transcript update from a realtime STT session. `partial` is a revising
/// interim for the current segment; `final` is a completed segment's text,
/// emitted once (it is appended by `CommitController.finalize`, not cumulative).
public enum TranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

/// A live streaming-transcription session: fed PCM as it is captured, emitting
/// `TranscriptEvent`s off-thread until `finish()`.
public protocol RealtimeSTTSession: Sendable {
    /// Opens the transport and sends any provider handshake/config.
    func start()
    /// Sends one raw-PCM chunk (16 kHz mono Int16). Called on the audio queue;
    /// conformers MUST keep this non-blocking.
    func send(_ pcm: Data)
    /// Flushes buffered audio, lets trailing finals arrive, then closes.
    func finish() async
}

/// Builds a `RealtimeSTTSession` for one capture. Conformers own their own URL,
/// auth, and wire format.
public protocol RealtimeSTTProvider: Sendable {
    func makeSession(
        baseURL: String,
        apiKey: String,
        language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession
}
```

- [ ] **Step 4: Add the Reson8 client conformance**

Append to `Reson8RealtimeClient.swift` (below the class):

```swift
// The client already exposes start()/send(_:)/finish() with matching signatures.
extension Reson8RealtimeClient: RealtimeSTTSession {}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RealtimeSTTSeam`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/RealtimeSTT.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeClient.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/RealtimeSTTTests.swift
git commit -m "feat(dictation): add RealtimeSTTProvider/Session streaming seam

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `DictationStateMachine` streaming mode (`DictationCore`)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/DictationCore/DictationStateMachine.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/DictationStateMachineTests.swift` (add cases; create if absent)

**Interfaces:**
- Consumes: nothing new.
- Produces: `DictationStateMachine.Mode` (`.batch`/`.streaming`); `Phase` += `.streaming`, `.finalizing`; `Action` += `.beginStreamingCapture`, `.endStreamingCapture`; `init(mode: Mode = .batch)`; `mutating func finalized() -> Action`. Batch transitions unchanged.

- [ ] **Step 1: Write the failing tests**

Add to `DictationStateMachineTests.swift` (inside its `@Suite`):

```swift
@Test func streamingStartFromIdle() {
    var m = DictationStateMachine(mode: .streaming)
    #expect(m.startOrToggle() == .beginStreamingCapture)
    #expect(m.phase == .streaming)
}
@Test func streamingToggleStops() {
    var m = DictationStateMachine(mode: .streaming)
    _ = m.startOrToggle()
    #expect(m.startOrToggle() == .endStreamingCapture)
    #expect(m.phase == .finalizing)
}
@Test func streamingReleaseStops() {
    var m = DictationStateMachine(mode: .streaming)
    _ = m.startOrToggle()
    #expect(m.release() == .endStreamingCapture)
    #expect(m.phase == .finalizing)
}
@Test func finalizedReturnsToIdle() {
    var m = DictationStateMachine(mode: .streaming)
    _ = m.startOrToggle(); _ = m.startOrToggle()   // now .finalizing
    #expect(m.finalized() == .none)
    #expect(m.phase == .idle)
}
@Test func finalizedNoopUnlessFinalizing() {
    var m = DictationStateMachine(mode: .streaming)
    #expect(m.finalized() == .none)
    #expect(m.phase == .idle)
}
@Test func failedFromStreamingRecovers() {
    var m = DictationStateMachine(mode: .streaming)
    _ = m.startOrToggle()
    #expect(m.failed("boom") == .showError("boom"))
    #expect(m.phase == .idle)
}
@Test func batchModeUnchanged() {
    var m = DictationStateMachine(mode: .batch)
    #expect(m.startOrToggle() == .beginCapture)
    #expect(m.phase == .listening)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationStateMachine`
Expected: FAIL — no `init(mode:)`, no `.streaming`/`.beginStreamingCapture`/`finalized`.

- [ ] **Step 3: Extend the state machine**

Replace the top of `DictationStateMachine.swift` through `startOrToggle`/`release`, and add `finalized()`:

```swift
public struct DictationStateMachine: Sendable {
    public enum Mode: Sendable { case batch, streaming }

    public enum Phase: Equatable, Sendable {
        case idle
        case listening       // batch capture
        case transcribing    // batch: file → text
        case inserting       // batch: pasting result
        case streaming       // live capture + live insertion
        case finalizing      // awaiting trailing finals after stop
    }

    public enum Action: Equatable, Sendable {
        case none
        case beginCapture
        case endCaptureAndTranscribe
        case insert(String)
        case showError(String)
        case showEmpty
        case beginStreamingCapture
        case endStreamingCapture
    }

    public private(set) var phase: Phase = .idle
    private let mode: Mode
    public init(mode: Mode = .batch) { self.mode = mode }

    public mutating func startOrToggle() -> Action {
        switch phase {
        case .idle:
            switch mode {
            case .batch:     phase = .listening; return .beginCapture
            case .streaming: phase = .streaming; return .beginStreamingCapture
            }
        case .listening:
            phase = .transcribing; return .endCaptureAndTranscribe
        case .streaming:
            phase = .finalizing; return .endStreamingCapture
        case .transcribing, .inserting, .finalizing:
            return .none
        }
    }

    public mutating func release() -> Action {
        switch phase {
        case .listening:
            phase = .transcribing; return .endCaptureAndTranscribe
        case .streaming:
            phase = .finalizing; return .endStreamingCapture
        default:
            return .none
        }
    }

    /// Streaming: trailing finals drained, capture torn down → back to idle.
    public mutating func finalized() -> Action {
        guard phase == .finalizing else { return .none }
        phase = .idle
        return .none
    }
```

Leave `transcriptReady`, `failed`, `inserted`, `reset` unchanged (the existing `failed` guard `phase != .idle` already covers `.streaming`/`.finalizing`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationStateMachine`
Expected: PASS (existing batch tests + 7 new).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/DictationStateMachine.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/DictationStateMachineTests.swift
git commit -m "feat(dictation): add streaming mode + phases to the state machine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Reson8 provider adapter + capability registry (`AudioPipelineJobs`)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeProvider.swift`
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/RealtimeProviderRegistry.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/RealtimeProviderRegistryTests.swift`

**Interfaces:**
- Consumes: `RealtimeSTTProvider`, `Reson8RealtimeClient`, `Reson8RealtimeURL`, `Reson8RealtimeOptions` (Task 1 + existing).
- Produces: `Reson8RealtimeProvider: RealtimeSTTProvider`; `RealtimeProviderRegistry.provider(for presetID: String) -> RealtimeSTTProvider?`. Capability = a non-nil return.

- [ ] **Step 1: Write the failing test**

```swift
// RealtimeProviderRegistryTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct RealtimeProviderRegistryResolution {
    @Test func reson8IsStreamingCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "reson8") != nil)
    }
    @Test func unknownPresetIsNotCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "elevenlabs") == nil)
    }
    @Test func reson8ProviderBuildsASession() throws {
        let p = Reson8RealtimeProvider()
        let session = try p.makeSession(
            baseURL: "https://api.reson8.dev", apiKey: "k", language: "es",
            onEvent: { _ in }, onError: { _ in })
        #expect(session is Reson8RealtimeClient)
    }
    @Test func reson8ProviderThrowsOnBadBaseURL() {
        #expect(throws: Reson8RealtimeURL.BuildError.self) {
            _ = try Reson8RealtimeProvider().makeSession(
                baseURL: "api.reson8.dev", apiKey: "k", language: "en",
                onEvent: { _ in }, onError: { _ in })
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RealtimeProviderRegistryResolution`
Expected: FAIL — `RealtimeProviderRegistry` / `Reson8RealtimeProvider` not found.

- [ ] **Step 3: Implement the adapter + registry**

```swift
// Reson8RealtimeProvider.swift
import Foundation

/// Adapts `Reson8RealtimeClient` to the `RealtimeSTTProvider` seam: derives the
/// wss URL from the provider base URL and maps the client's split callbacks onto
/// a single `onEvent`.
public struct Reson8RealtimeProvider: RealtimeSTTProvider {
    public init() {}
    public func makeSession(
        baseURL: String, apiKey: String, language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession {
        let url = try Reson8RealtimeURL.make(
            baseURL: baseURL,
            options: Reson8RealtimeOptions(language: language))
        return Reson8RealtimeClient(
            url: url, apiKey: apiKey,
            onPartial: { onEvent(.partial($0)) },
            onFinal: { onEvent(.final($0)) },
            onError: onError)
    }
}
```

```swift
// RealtimeProviderRegistry.swift
import Foundation

/// Single source of truth for "which providers can stream." A non-nil result
/// both selects the adapter and gates the "Stream results live" toggle.
public enum RealtimeProviderRegistry {
    public static func provider(for presetID: String) -> RealtimeSTTProvider? {
        switch presetID {
        case "reson8": return Reson8RealtimeProvider()
        // "soniox" added in Task 11.
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RealtimeProviderRegistryResolution`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeProvider.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/RealtimeProviderRegistry.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/RealtimeProviderRegistryTests.swift
git commit -m "feat(dictation): add Reson8 realtime adapter + capability registry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `DictationSettings` streaming fields (`DictationCore`)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/DictationSettingsTests.swift` (add cases; create if absent)

**Interfaces:**
- Produces: `DictationSettings.streamLive: Bool` (default `false`), `DictationSettings.language: String` (default `"en"`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func defaultsAreBatchEnglish() {
    let s = DictationSettings.default
    #expect(s.streamLive == false)
    #expect(s.language == "en")
}
@Test func codableRoundTripPreservesStreamingFields() throws {
    var s = DictationSettings.default
    s.streamLive = true
    s.language = "de"
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(DictationSettings.self, from: data)
    #expect(back.streamLive == true)
    #expect(back.language == "de")
}
@Test func decodesLegacyBlobWithoutStreamingFields() throws {
    // A pre-M3 persisted blob has neither key; decoding must not fail.
    let legacy = #"{"enabled":false,"trigger":"rightCommand","holdThresholdMs":250,"model":"whisper-large-v3-turbo","insertMode":"autoInsert","showOverlay":false,"keepAudio":false}"#
    let s = try JSONDecoder().decode(DictationSettings.self, from: Data(legacy.utf8))
    #expect(s.streamLive == false)
    #expect(s.language == "en")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettings`
Expected: FAIL — `value of type 'DictationSettings' has no member 'streamLive'`. (The legacy-decode test will also fail to compile until the fields exist.)

- [ ] **Step 3: Add the fields with defaults**

`DictationSettings` is a plain `Codable` struct with a memberwise `init` supplying defaults. Because a synthesized `Codable` still requires every stored property's key OR a default *at decode time*, add a custom `init(from:)` that tolerates missing keys (needed for legacy blobs). Edit `DictationSettings.swift`:

```swift
public struct DictationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var trigger: TriggerModifier
    public var holdThresholdMs: Int
    public var providerID: UUID?
    public var model: String
    public var insertMode: InsertMode
    public var showOverlay: Bool
    public var keepAudio: Bool
    public var streamLive: Bool
    public var language: String

    public init(
        enabled: Bool = false,
        trigger: TriggerModifier = .rightCommand,
        holdThresholdMs: Int = 250,
        providerID: UUID? = nil,
        model: String = "whisper-large-v3-turbo",
        insertMode: InsertMode = .autoInsert,
        showOverlay: Bool = false,
        keepAudio: Bool = false,
        streamLive: Bool = false,
        language: String = "en"
    ) {
        self.enabled = enabled
        self.trigger = trigger
        self.holdThresholdMs = holdThresholdMs
        self.providerID = providerID
        self.model = model
        self.insertMode = insertMode
        self.showOverlay = showOverlay
        self.keepAudio = keepAudio
        self.streamLive = streamLive
        self.language = language
    }

    // Tolerant decode: a pre-M3 persisted blob has neither streaming key.
    // `decodeIfPresent` + defaults keeps old installs loading cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        trigger = try c.decode(TriggerModifier.self, forKey: .trigger)
        holdThresholdMs = try c.decode(Int.self, forKey: .holdThresholdMs)
        providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        model = try c.decode(String.self, forKey: .model)
        insertMode = try c.decode(InsertMode.self, forKey: .insertMode)
        showOverlay = try c.decode(Bool.self, forKey: .showOverlay)
        keepAudio = try c.decode(Bool.self, forKey: .keepAudio)
        streamLive = try c.decodeIfPresent(Bool.self, forKey: .streamLive) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
    }

    public static let `default` = DictationSettings()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettings`
Expected: PASS (3 new + any existing).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/DictationSettingsTests.swift
git commit -m "feat(dictation): add streamLive + language to DictationSettings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Overlay streaming states (app target)

> **⚠️ Spec deviation (flagged for approval):** the spec said "reuse `DictationOverlayController` for the volatile tail," but the overlay is a phase pill with no live-text canvas. This task adds a **"Dictating…" phase pill** (the live words appear in the target app, which is the point). Rendering the live volatile tail *inside* the overlay is deferred. If you want the live tail in the HUD, this task grows to thread a text string through `DictationOverlayModel`/`View`.

**Files:**
- Modify: `Amanuensis/UI/DictationOverlayView.swift` (add `.dictating` state + rendering)
- Modify: `Amanuensis/UI/DictationOverlayController.swift` (map new phases)

**Interfaces:**
- Consumes: `DictationStateMachine.Phase.streaming`/`.finalizing` (Task 2).
- Produces: overlay renders during streaming/finalizing.

- [ ] **Step 1: Add the overlay state + view**

In `DictationOverlayView.swift`, add a case to `DictationOverlayState` and its `content`:

```swift
enum DictationOverlayState: Equatable {
    case listening
    case transcribing
    case inserted
    case dictating       // live streaming
    case flash(String)
}
```

Add to the `content` switch (before `.flash`):

```swift
case .dictating:
    pill {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeating)
        Text("Dictating…")
    }
```

- [ ] **Step 2: Map the new phases in the controller**

In `DictationOverlayController.swift`, extend `state(for:)` to be exhaustive over the new phases:

```swift
private static func state(for phase: DictationStateMachine.Phase) -> DictationOverlayState? {
    switch phase {
    case .idle: return nil
    case .listening: return .listening
    case .transcribing: return .transcribing
    case .inserting: return .inserted
    case .streaming: return .dictating
    case .finalizing: return .transcribing
    }
}
```

- [ ] **Step 3: Build the app target to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED (exhaustive-switch errors gone).

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/DictationOverlayView.swift Amanuensis/UI/DictationOverlayController.swift
git commit -m "feat(dictation): add Dictating overlay state for streaming phases

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Coordinator streaming path (app target)

This is the integration task: mode resolution, the async connect, the audio→session fan, the off-thread→MainActor `AsyncStream` bridge, and teardown. It is `@MainActor` integration code validated by the DEBUG smoke (Task 12) and by the state-machine unit tests (Task 2), not by a new unit test (the coordinator has no seam for injecting a fake provider without a refactor that is out of scope).

**Files:**
- Modify: `Amanuensis/Dictation/DictationCoordinator.swift`

**Interfaces:**
- Consumes: `RealtimeProviderRegistry`, `RealtimeSTTProvider`/`RealtimeSTTSession`, `TranscriptEvent` (Tasks 1, 3); `CommitController`, `KeystrokeDiffInserter`; `DictationStateMachine(mode:)`, `finalized()` (Task 2); `DictationSettings.streamLive`/`.language` (Task 4).
- Produces: end-to-end Reson8 streaming through the real hotkey.

- [ ] **Step 1: Add streaming state + a mode resolver**

Add stored properties (near the existing `recorder`/`transcribeTask` block):

```swift
    // Streaming
    private var commit = CommitController(stabilityCount: 3)
    private let streamInserter = KeystrokeDiffInserter()
    private var streamingSession: (any RealtimeSTTSession)?
    private var streamContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var streamConsumeTask: Task<Void, Never>?
    private var streamSetupTask: Task<Void, Never>?
    private var isStoppingStream = false
```

Add the resolver (near `resolveTranscriberInputs`):

```swift
    /// Streaming iff enabled in settings AND the selected provider has an adapter.
    private func currentMode() -> DictationStateMachine.Mode {
        guard settings.dictation.streamLive,
              let pid = settings.dictation.providerID,
              let provider = providerLookup(pid),
              RealtimeProviderRegistry.provider(for: provider.presetID) != nil
        else { return .batch }
        return .streaming
    }

    private struct StreamingInputs { let provider: Provider; let realtime: any RealtimeSTTProvider }

    private func resolveStreamingInputs() -> StreamingInputs? {
        guard let pid = settings.dictation.providerID,
              let provider = providerLookup(pid),
              let realtime = RealtimeProviderRegistry.provider(for: provider.presetID)
        else { return nil }
        return StreamingInputs(provider: provider, realtime: realtime)
    }
```

- [ ] **Step 2: Pick the mode fresh at each capture start**

In `applyGesture`, change the `.toggle, .pttStart` case so the machine is (re)built with the current mode when idle:

```swift
        case .toggle, .pttStart:
            if machine.phase == .idle {
                machine = DictationStateMachine(mode: currentMode())
            }
            applyAction(machine.startOrToggle())
        case .pttEnd:
            applyAction(machine.release())
```

- [ ] **Step 3: Route the new actions**

In `applyAction`, add two cases (alongside `.beginCapture`/`.endCaptureAndTranscribe`):

```swift
        case .beginStreamingCapture:
            beginStreamingCapture()
        case .endStreamingCapture:
            endStreamingCapture()
```

- [ ] **Step 4: Implement the streaming effects**

Add these methods (near `beginCapture`/`endCaptureAndTranscribe`):

```swift
    private func beginStreamingCapture() {
        guard let inputs = resolveStreamingInputs() else {
            log("Dictation: no streaming provider configured")
            overlay.flash("Set a streaming dictation provider in Settings")
            _ = machine.failed("no streaming provider")
            phase = machine.phase
            return
        }
        isStoppingStream = false
        commit = CommitController(stabilityCount: 3)
        streamInserter.reset()
        _ = TextInserter.requestPostEventAccess()

        let url = tempStore.newCaptureURL()
        captureURL = url

        // Off-thread client callbacks → this MainActor via a single stream.
        let (stream, cont) = AsyncStream<TranscriptEvent>.makeStream()
        streamContinuation = cont
        streamConsumeTask = Task { [weak self] in
            for await event in stream { self?.handleStreamEvent(event) }
        }

        // Async connect: key fetch → session → mic. Runs on this MainActor
        // (default isolation), so the property writes are hop-free.
        streamSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let apiKey = try await self.keychain.get(account: inputs.provider.apiKeyRef.account)
                if Task.isCancelled { return }
                let session = try inputs.realtime.makeSession(
                    baseURL: inputs.provider.baseURL,
                    apiKey: apiKey,
                    language: self.settings.dictation.language,
                    onEvent: { cont.yield($0) },
                    onError: { [weak self] error in
                        Task { @MainActor in self?.handleStreamError(error) }
                    })
                session.start()
                let rec = try DictationRecorder(
                    url: url,
                    onLevel: { [weak self] lvl in Task { @MainActor in self?.level = lvl } },
                    onChunk: { session.send($0) })
                try rec.start()
                self.streamingSession = session
                self.recorder = rec
            } catch {
                self.log("Dictation streaming setup failed: \(error.localizedDescription)")
                self.overlay.flash("Dictation provider unavailable")
                self.teardownStream(delete: true)
                _ = self.machine.failed(error.localizedDescription)
                self.phase = self.machine.phase
            }
        }
    }

    private func handleStreamEvent(_ event: TranscriptEvent) {
        switch event {
        case .partial(let t): commit.update(partial: t)
        case .final(let t): commit.finalize(t)
        }
        _ = streamInserter.apply(committed: commit.committed, fullHypothesis: commit.fullHypothesis)
    }

    private func handleStreamError(_ error: Error) {
        if isStoppingStream { return }   // benign: our own finish()/cancel
        log("Dictation streaming error: \(error.localizedDescription)")
        overlay.flash("Dictation connection failed")
        teardownStream(delete: true)
        _ = machine.failed(error.localizedDescription)
        phase = machine.phase
    }

    /// Normal stop: flush the socket, drain trailing finals, then idle.
    private func endStreamingCapture() {
        streamSetupTask?.cancel(); streamSetupTask = nil
        isStoppingStream = true
        let session = streamingSession; streamingSession = nil
        let rec = recorder; recorder = nil
        let cont = streamContinuation; streamContinuation = nil
        let consume = streamConsumeTask; streamConsumeTask = nil
        let url = captureURL; captureURL = nil
        Task { [weak self] in
            _ = await rec?.stop()
            await session?.finish()   // trailing finals arrive via cont → handleStreamEvent
            cont?.finish()
            await consume?.value
            if let url { self?.tempStore.delete(url) }
            self?.applyAction(self?.machine.finalized() ?? .none)
        }
    }

    /// Error/abort teardown (no finalize transition; caller drives the machine).
    private func teardownStream(delete: Bool) {
        isStoppingStream = true
        streamSetupTask?.cancel(); streamSetupTask = nil
        streamConsumeTask?.cancel(); streamConsumeTask = nil
        streamContinuation?.finish(); streamContinuation = nil
        let session = streamingSession; streamingSession = nil
        let rec = recorder; recorder = nil
        let url = captureURL; captureURL = nil
        Task {
            _ = await rec?.stop()
            await session?.finish()
            if delete, let url { tempStore.delete(url) }
        }
    }
```

- [ ] **Step 5: Extend `abortCapture` to tear down a live stream**

`abortCapture` (called on dictation-disable / provider-removed) currently only knows about the batch recorder. Add streaming teardown at its top so a mid-stream disable is clean. Insert immediately after the `holdTask?.cancel()` line:

```swift
        if streamingSession != nil || streamSetupTask != nil || streamContinuation != nil {
            teardownStream(delete: true)
        }
```

- [ ] **Step 6: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED. (Concurrency check: the `onChunk`/`onLevel`/`onEvent`/`onError` closures are `@Sendable`; they capture only `Sendable` values — `session` (a `RealtimeSTTSession: Sendable`) and the `AsyncStream.Continuation`. If the compiler flags a MainActor-capture in `onChunk`, confirm it captures `session` only, never `self` — see [[feedback_mainactor_closure_sendable_audio]].)

- [ ] **Step 7: Commit**

```bash
git add Amanuensis/Dictation/DictationCoordinator.swift
git commit -m "feat(dictation): drive live streaming through the real coordinator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Settings UI — toggle + language (app target)

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift`

**Interfaces:**
- Consumes: `settings.dictation.streamLive`/`.language` (Task 4); `RealtimeProviderRegistry` (Task 3); `coordinator.dictation.settingsChanged()`.
- Produces: the streaming toggle (capability-gated) + language picker.

- [ ] **Step 1: Add a capability helper**

In `SettingsView`, add a computed check for whether the selected provider can stream:

```swift
    private var selectedProviderStreams: Bool {
        guard let pid = settings.dictation.providerID,
              let provider = coordinator.allProviders.first(where: { $0.id == pid })
        else { return false }
        return RealtimeProviderRegistry.provider(for: provider.presetID) != nil
    }
```

- [ ] **Step 2: Add the toggle + language picker**

In the `Section("Dictation")`, immediately after the `Picker("Provider", …)` block (and before `TextField("Model", …)`), insert:

```swift
                Toggle("Stream results live", isOn: $settings.dictation.streamLive)
                    .disabled(!selectedProviderStreams)
                    .onChange(of: settings.dictation.streamLive) { _, _ in
                        coordinator.dictation.settingsChanged()
                    }
                if settings.dictation.streamLive && selectedProviderStreams {
                    Picker("Language", selection: $settings.dictation.language) {
                        ForEach(dictationLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                } else if !selectedProviderStreams {
                    Text("The selected provider doesn’t support live streaming.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

Add the curated list as a file-scope constant at the bottom of `SettingsView.swift`:

```swift
// Curated BCP-47 list for streaming dictation. Providers map/validate their own
// supported codes; this is a shared starter set, extendable later.
private let dictationLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
    ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
]
```

- [ ] **Step 3: Confirm `settingsChanged()` re-derives mode**

`settingsChanged()` (Task 6 leaves it as-is) re-arms the monitor; mode is re-picked at the next capture start (Task 6, Step 2), so toggling `streamLive` needs no extra wiring. Verify by reading `settingsChanged()` — no code change required here.

- [ ] **Step 4: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke (Phase A deliverable)**

With a Reson8 provider configured + its key in Keychain: Settings → select the Reson8 provider → "Stream results live" enables → toggle on → pick English → press the dictation hotkey in TextEdit and speak. Words appear live. Release to stop.

- [ ] **Step 6: Commit**

```bash
git add Amanuensis/UI/SettingsView.swift
git commit -m "feat(dictation): add streaming toggle + language picker to Settings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Soniox realtime URL (`AudioPipelineJobs`)

> **Wire-format note:** Soniox's realtime endpoint, config field names, and token shape (Tasks 8–10) must be confirmed against the current Soniox realtime WebSocket docs. The *structure* below is fixed (mirrors the Reson8 trio); the flagged constants are the unknowns. Every Soniox task carries a verification step.

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeURL.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxRealtimeURLTests.swift`

**Interfaces:**
- Produces: `SonioxRealtimeURL.make() -> URL` — the fixed realtime `wss` endpoint (Soniox realtime uses its own host, not the batch `api.soniox.com`; auth + config go in the first message, not the query string).

- [ ] **Step 1: Verify the endpoint**

Confirm the realtime WS URL in Soniox's docs (as of writing: `wss://stt-rt.soniox.com/transcribe-websocket`). Update the constant in Step 3 if it differs.

- [ ] **Step 2: Write the failing test**

```swift
// SonioxRealtimeURLTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct SonioxRealtimeURLBuilding {
    @Test func isSecureWebSocket() {
        let url = SonioxRealtimeURL.make()
        #expect(url.scheme == "wss")
        #expect(url.host == "stt-rt.soniox.com")
        #expect(url.path == "/transcribe-websocket")
    }
}
```

- [ ] **Step 3: Implement**

```swift
// SonioxRealtimeURL.swift
import Foundation

/// The Soniox Realtime WebSocket endpoint. Unlike Reson8, Soniox realtime uses a
/// dedicated host and carries auth + audio config in the first message, so there
/// is no per-provider base URL or query string to build.
public enum SonioxRealtimeURL {
    // Verified against Soniox realtime docs (Task 8, Step 1).
    public static func make() -> URL {
        URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxRealtimeURLBuilding`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeURL.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxRealtimeURLTests.swift
git commit -m "feat(dictation): add Soniox realtime endpoint URL

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Soniox realtime decoder + token folding (`AudioPipelineJobs`)

Soniox streams **tokens** (each with an `is_final` flag), not whole-transcript strings like Reson8. The current message's final tokens are locked; its non-final tokens are the revising tail. To satisfy the same `CommitController` contract as Reson8 (partials = current-segment hypothesis; `final` = one completed segment, appended once), we split into a pure per-frame decoder and a small stateful folder.

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeDecoder.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxRealtimeDecoderTests.swift`

**Interfaces:**
- Produces: `SonioxToken { text: String; isFinal: Bool }`; `SonioxRealtimeFrame { tokens: [SonioxToken]; finished: Bool }`; `SonioxRealtimeDecoder.decode(_ json: String) -> SonioxRealtimeFrame`; `SonioxTranscriptFolder` (`mutating func fold(_ frame:) -> [TranscriptEvent]`).

- [ ] **Step 1: Verify the token JSON shape**

Confirm against Soniox realtime docs: message shape `{"tokens":[{"text":"…","is_final":true|false}], "finished":true?}` and the end-of-utterance signal. Adjust `CodingKeys`/`finished` handling in Step 3 to match.

- [ ] **Step 2: Write the failing tests**

```swift
// SonioxRealtimeDecoderTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct SonioxRealtimeDecoding {
    @Test func decodesFinalAndNonFinalTokens() {
        let f = SonioxRealtimeDecoder.decode(#"{"tokens":[{"text":"the ","is_final":true},{"text":"pat","is_final":false}]}"#)
        #expect(f.tokens == [SonioxToken(text: "the ", isFinal: true),
                             SonioxToken(text: "pat", isFinal: false)])
        #expect(f.finished == false)
    }
    @Test func missingIsFinalDefaultsToNonFinal() {
        let f = SonioxRealtimeDecoder.decode(#"{"tokens":[{"text":"hi"}]}"#)
        #expect(f.tokens == [SonioxToken(text: "hi", isFinal: false)])
    }
    @Test func malformedFrameIsEmpty() {
        let f = SonioxRealtimeDecoder.decode("not json")
        #expect(f.tokens.isEmpty)
        #expect(f.finished == false)
    }

    // Folder: final tokens accumulate; non-final is the revising tail; a
    // `finished` frame emits the completed segment once and resets.
    @Test func folderEmitsRevisingPartialsThenOneFinal() {
        var folder = SonioxTranscriptFolder()
        let e1 = folder.fold(.init(tokens: [.init(text: "the ", isFinal: true),
                                            .init(text: "pat", isFinal: false)], finished: false))
        #expect(e1 == [.partial("the pat")])
        let e2 = folder.fold(.init(tokens: [.init(text: "patient", isFinal: true)], finished: false))
        #expect(e2 == [.partial("the patient")])
        let e3 = folder.fold(.init(tokens: [], finished: true))
        #expect(e3 == [.final("the patient")])
        // Next segment starts clean.
        let e4 = folder.fold(.init(tokens: [.init(text: "next", isFinal: false)], finished: false))
        #expect(e4 == [.partial("next")])
    }
}
```

- [ ] **Step 3: Implement decoder + folder**

```swift
// SonioxRealtimeDecoder.swift
import Foundation

public struct SonioxToken: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

public struct SonioxRealtimeFrame: Sendable, Equatable {
    public let tokens: [SonioxToken]
    public let finished: Bool
    public init(tokens: [SonioxToken], finished: Bool) { self.tokens = tokens; self.finished = finished }
}

/// Pure per-frame decode. Never throws — a stray frame decodes to an empty frame
/// so it can't tear down the stream.
public enum SonioxRealtimeDecoder {
    private struct Message: Decodable {
        struct Token: Decodable {
            let text: String?
            let isFinal: Bool?
            enum CodingKeys: String, CodingKey { case text; case isFinal = "is_final" }
        }
        let tokens: [Token]?
        let finished: Bool?
    }

    public static func decode(_ json: String) -> SonioxRealtimeFrame {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            return SonioxRealtimeFrame(tokens: [], finished: false)
        }
        let tokens = (msg.tokens ?? []).map {
            SonioxToken(text: $0.text ?? "", isFinal: $0.isFinal ?? false)
        }
        return SonioxRealtimeFrame(tokens: tokens, finished: msg.finished ?? false)
    }
}

/// Folds Soniox's token frames into the `CommitController` contract: final tokens
/// accumulate into the current segment; each frame emits the current hypothesis
/// (accumulated finals + this frame's non-final tail) as a `.partial`; a
/// `finished` frame emits the segment once as `.final` and resets.
public struct SonioxTranscriptFolder: Sendable {
    private var segmentFinal = ""
    public init() {}

    public mutating func fold(_ frame: SonioxRealtimeFrame) -> [TranscriptEvent] {
        segmentFinal += frame.tokens.filter { $0.isFinal }.map(\.text).joined()
        if frame.finished {
            let done = segmentFinal.trimmingCharacters(in: .whitespaces)
            segmentFinal = ""
            return done.isEmpty ? [] : [.final(done)]
        }
        let tail = frame.tokens.filter { !$0.isFinal }.map(\.text).joined()
        let hypothesis = (segmentFinal + tail).trimmingCharacters(in: .whitespaces)
        return hypothesis.isEmpty ? [] : [.partial(hypothesis)]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxRealtimeDecoding`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeDecoder.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxRealtimeDecoderTests.swift
git commit -m "feat(dictation): add Soniox realtime token decoder + folder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Soniox realtime client (`AudioPipelineJobs`)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeClient.swift`

**Interfaces:**
- Consumes: `SonioxRealtimeURL`, `SonioxRealtimeDecoder`, `SonioxTranscriptFolder`, `TranscriptEvent`.
- Produces: `SonioxRealtimeClient: RealtimeSTTSession` — `init(url:apiKey:model:language:session:onEvent:onError:)`, config-first `start()`, binary-frame `send(_:)`, `finish()`.

- [ ] **Step 1: Verify the config message + finish sentinel**

Confirm against Soniox realtime docs: the first message's JSON keys (`api_key`, `model`, `audio_format`, `sample_rate`, `num_channels`, `language_hints`) and how a client signals end-of-audio (typically an empty binary/text frame). Adjust Step 2 to match.

- [ ] **Step 2: Implement the client**

```swift
// SonioxRealtimeClient.swift
import Foundation
import os

/// Drives a Soniox Realtime WebSocket. Unlike Reson8 (header auth, whole-string
/// transcripts), Soniox authenticates in a JSON config *first message* and streams
/// tokens, folded into `TranscriptEvent`s by `SonioxTranscriptFolder`.
/// `@unchecked Sendable`: `send(_:)` (audio queue) and the receive loop
/// (URLSession delegate queue) both funnel through the thread-safe task; `folder`
/// is only ever touched inside the receive loop.
public final class SonioxRealtimeClient: RealtimeSTTSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let configMessage: String
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let onError: @Sendable (Error) -> Void
    private var folder = SonioxTranscriptFolder()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "soniox-rt")

    public init(url: URL = SonioxRealtimeURL.make(),
                apiKey: String,
                model: String = "stt-rt-preview",
                language: String,
                session: URLSession = .shared,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.task = session.webSocketTask(with: url)
        self.onEvent = onEvent
        self.onError = onError
        // Verified field names (Task 10, Step 1).
        let config: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "language_hints": [language],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data()
        self.configMessage = String(decoding: data, as: UTF8.self)
    }

    public func start() {
        task.resume()
        task.send(.string(configMessage)) { [log] error in
            if let error { log.error("config send failed: \(error.localizedDescription, privacy: .public)") }
        }
        receive()
    }

    public func send(_ pcm: Data) {
        task.send(.data(pcm)) { [log] error in
            if let error { log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    public func finish() async {
        // Soniox ends the stream on an empty audio frame; then wait for trailing
        // finals before closing.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.send(.data(Data())) { _ in cont.resume() }
        }
        try? await Task.sleep(for: .seconds(1))
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onError(error)
            case .success(let message):
                if case .string(let text) = message {
                    let frame = SonioxRealtimeDecoder.decode(text)
                    for event in self.folder.fold(frame) { self.onEvent(event) }
                }
                self.receive()
            }
        }
    }
}
```

- [ ] **Step 3: Build the package**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: Build complete. (No unit test — the socket is exercised in the Task 12 smoke.)

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeClient.swift
git commit -m "feat(dictation): add Soniox realtime WebSocket client

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Soniox provider adapter + registry entry (`AudioPipelineJobs`)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeProvider.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/RealtimeProviderRegistry.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/RealtimeProviderRegistryTests.swift` (add a case)

**Interfaces:**
- Produces: `SonioxRealtimeProvider: RealtimeSTTProvider`; registry maps `"soniox"` → it.

- [ ] **Step 1: Write the failing test**

Add to `RealtimeProviderRegistryResolution`:

```swift
    @Test func sonioxIsStreamingCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "soniox") != nil)
    }
    @Test func sonioxProviderBuildsASession() throws {
        let session = try SonioxRealtimeProvider().makeSession(
            baseURL: "https://api.soniox.com", apiKey: "k", language: "en",
            onEvent: { _ in }, onError: { _ in })
        #expect(session is SonioxRealtimeClient)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RealtimeProviderRegistryResolution`
Expected: FAIL — `provider(for: "soniox")` is nil; `SonioxRealtimeProvider` not found.

- [ ] **Step 3: Implement the adapter + register it**

```swift
// SonioxRealtimeProvider.swift
import Foundation

/// Adapts `SonioxRealtimeClient` to the `RealtimeSTTProvider` seam. `baseURL` is
/// unused — Soniox realtime uses its own fixed endpoint (`SonioxRealtimeURL`).
public struct SonioxRealtimeProvider: RealtimeSTTProvider {
    public init() {}
    public func makeSession(
        baseURL: String, apiKey: String, language: String,
        onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession {
        SonioxRealtimeClient(
            apiKey: apiKey, language: language,
            onEvent: onEvent, onError: onError)
    }
}
```

In `RealtimeProviderRegistry.swift`, add the case:

```swift
        case "soniox": return SonioxRealtimeProvider()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RealtimeProviderRegistryResolution`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxRealtimeProvider.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/RealtimeProviderRegistry.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/RealtimeProviderRegistryTests.swift
git commit -m "feat(dictation): register Soniox as a streaming provider

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Full-suite verification + Soniox smoke + app rebuild

**Files:** none (verification only). Optional: a `presets.json` `soniox` entry if one isn't already present (so a Soniox provider can be created in-app).

- [ ] **Step 1: Confirm a `soniox` preset exists**

Read `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`. If there is no provider preset whose `presetID`/`id` is `"soniox"`, the capability registry can never match a user's Soniox provider. If absent, add a `soniox` preset (mirror the existing `reson8` entry: name, `presetID: "soniox"`, `baseURL: "https://api.soniox.com"`, its batch `shape`). If a Soniox preset already exists under a different id, align `RealtimeProviderRegistry`'s case string to it instead. Commit any change:

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json
git commit -m "chore(dictation): ensure a soniox provider preset exists

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 2: Run the full SPM suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all suites green (the pre-existing count + the new `RealtimeSTTSeam`, `DictationStateMachine` streaming cases, `DictationSettings`, `RealtimeProviderRegistryResolution`, `SonioxRealtimeURLBuilding`, `SonioxRealtimeDecoding`).

- [ ] **Step 3: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual smoke — both adapters through the real hotkey**

For each of Reson8 and Soniox: configure the provider + Keychain key in-app, select it as the dictation provider, enable "Stream results live", press the dictation hotkey in TextEdit, speak, and confirm words appear live and stop cleanly on release. Confirm a batch-only provider (e.g. ElevenLabs) greys the toggle out. Confirm toggling `streamLive` off restores batch dictation.

- [ ] **Step 5: (Optional) Retire or keep the DEBUG spike harness**

The real coordinator path now supersedes `Reson8SpikeHarness`. Keep it for isolated socket debugging, or delete it + its `AmanuensisApp.swift` DEBUG menu entries if the real path is trusted. Author's recommendation: keep through one release, then remove. No code change required either way.

---

## Self-Review

**Spec coverage** (against `2026-07-03-realtime-streaming-asr-m3-production-design.md`):
- §3 streaming seam → Task 1 (placed in `AudioPipelineJobs`, not `DictationCore` — see Deviations).
- §4 state machine + coordinator + MainActor hop → Tasks 2 (machine) + 6 (coordinator `AsyncStream` bridge; `ResultRef` untouched for batch).
- §5 capability registry, no keyless carve-out → Tasks 3 + 11.
- §6 Soniox adapter (URL/decoder/client + provider) → Tasks 8–11.
- §7 settings (`streamLive`/`language` + UI) → Tasks 4 + 7.
- §8 testing (state machine, fake session, Soniox URL/decoder, DEBUG smoke, rebuild) → Tasks 1,2,4,8,9,12.
- §9 out-of-scope respected: batch path untouched, keystroke strategy fixed, no keyless providers.

**Deviations from spec (surfaced, not silent):**
1. **Seam placement:** `Package.swift` shows `AudioPipelineJobs` and `DictationCore` are independent siblings. Putting the seam + adapters + registry in `AudioPipelineJobs` (not `DictationCore`) makes them SPM-testable and co-locates them with the wire clients, with no new module edge. Better than the spec's app-target-conformer plan.
2. **Overlay (Task 5):** the overlay is a phase pill, not a text canvas; M3 shows a "Dictating…" pill and defers rendering the live volatile tail in the HUD. **Needs your OK.**

**Placeholder scan:** no TBD/TODO left. The Soniox wire constants (endpoint host, config keys, finish sentinel, token shape) are real first-cut values with explicit "verify against docs" steps (Tasks 8–10, Step 1) — the acknowledged known-unknown from spec §10, not placeholders.

**Type consistency:** `TranscriptEvent`, `RealtimeSTTSession.send(_:)/start()/finish()`, `RealtimeSTTProvider.makeSession(baseURL:apiKey:language:onEvent:onError:)`, `RealtimeProviderRegistry.provider(for:)`, `DictationStateMachine(mode:)`/`finalized()`, `SonioxTranscriptFolder.fold(_:)` are used identically across tasks.
