# Streaming-Dictation Commit-Window Spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and evaluate the commit-window + continuous-pasting engine for live dictation, driven by *simulated* transcript chunks (no provider), so we can decide go/no-go and pick an insertion strategy + commit policy before any WebSocket work.

**Architecture:** Pure logic (`reconcile`, `CommitController`, `SimulatedTranscriptSource`, fixtures) lives in the `DictationCore` SPM module and is covered by the fast autonomous Swift Testing suite. AppKit-touching code (two `InsertionStrategy` impls, the `StreamingSpikeHarness`, a minimal floating overlay, a DEBUG menu) lives in the app target. The simulated source drives the existing `DictationTranscriber` `onPartial`/`onFinal` seam; the harness consumes events on the MainActor via an `AsyncStream`, feeds the `CommitController`, and routes its output to the chosen strategy and overlay.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, AppKit/CoreGraphics (`CGEvent`, `NSPasteboard`, `NSPanel`), the existing `TextInserter`.

## Global Constraints

- Swift tools 6.2; macOS deployment target **26.3**.
- `DictationCore` target uses `nonisolatedSettings` (NO MainActor default isolation). All new `DictationCore` types are nonisolated; concurrency-crossing types must be `Sendable`.
- App target default actor isolation is **MainActor** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); new app types are implicitly `@MainActor`.
- Tests use **Swift Testing** (`import Testing`, `@Test func …`, `#expect(…)`), free functions, matching existing `DictationCoreTests` style.
- **SPM test command (sandbox):** `swift test --disable-sandbox --package-path Packages/AudioPipeline` (add `--filter <name>` for one test).
- **App build command (sandbox):** `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`.
- **No new SPM dependencies. No new entitlements.** Text insertion reuses the existing Post-Event access (`CGPreflightPostEventAccess`/`CGRequestPostEventAccess`) already wired in `TextInserter`.
- New files under `Amanuensis/` are auto-registered by the `PBXFileSystemSynchronizedRootGroup` (no `project.pbxproj` edits). New files under `Packages/AudioPipeline/Sources/DictationCore/` are automatically part of the target.
- The harness, overlay, and Debug menu are compiled **`#if DEBUG` only**.
- Conventional commits; one commit per task. Working branch: `worktree-research+realtime-streaming-asr`.
- Spec: `docs/superpowers/specs/2026-06-30-realtime-streaming-asr-commit-window-spike-design.md`. This plan refines two spec details: (a) `CommitController` exposes observable state (`committed`/`volatileTail`/`fullHypothesis`) instead of callbacks; (b) the two strategies consume *different* targets — clipboard inserts only `committed` (stabilized) text, keystroke inserts the full evolving `fullHypothesis`. Both refinements preserve the spec's intent (compare append-only vs in-place revision) and are noted where they occur.

---

## File Structure

**DictationCore (pure, SPM-tested) — `Packages/AudioPipeline/Sources/DictationCore/`**
- `TranscriptReconcile.swift` — `TextDiff`, `reconcile(from:to:)`, internal LCP + word-boundary helpers, `InsertionResult`.
- `StreamingTranscript.swift` — `ScriptKind`, `ScriptEvent`, `SimulatedTranscriptScript` + static fixtures.
- `CommitController.swift` — the commit-window state machine.
- `SimulatedTranscriptSource.swift` — `DictationTranscriber` conformer replaying a script with injected sleep.

**Tests — `Packages/AudioPipeline/Tests/DictationCoreTests/`**
- `TranscriptReconcileTests.swift`, `StreamingTranscriptTests.swift`, `CommitControllerTests.swift`, `SimulatedTranscriptSourceTests.swift`.

**App target (AppKit) — `Amanuensis/Dictation/Streaming/`**
- `InsertionStrategy.swift` — protocol.
- `ClipboardAppendInserter.swift` — append-only via `TextInserter`.
- `KeystrokeDiffInserter.swift` — keystroke + backspace-diff via `CGEvent`.
- `StreamingSpikeHarness.swift` — wires source × commit × strategy, metrics, overlay.
- `SpikeOverlayPanel.swift` — minimal floating panel for the volatile tail.
- Modify `Amanuensis/AmanuensisApp.swift` — add a `#if DEBUG` `CommandMenu`.

---

## Task 1: Reconcile + diff primitives (DictationCore)

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/TranscriptReconcile.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/TranscriptReconcileTests.swift`

**Interfaces:**
- Produces: `public struct TextDiff: Equatable, Sendable { public let backspaces: Int; public let insert: String }`; `public func reconcile(from old: String, to new: String) -> TextDiff`; `public enum InsertionResult: Equatable, Sendable { case appended(chars: Int), revised(backspaces: Int, inserted: Int), revisionMiss, noop }`; internal `func longestCommonPrefix(_ a: String, _ b: String) -> String`, `func longestCommonPrefix(of strings: [String]) -> String`, `func trimToLastWordBoundary(_ s: String) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
// TranscriptReconcileTests.swift
import Testing
@testable import DictationCore

@Suite struct TranscriptReconcileTests {
    @Test func reconcilePureAppend() {
        #expect(reconcile(from: "ab", to: "abc") == TextDiff(backspaces: 0, insert: "c"))
    }

    @Test func reconcileReplaceSuffix() {
        #expect(reconcile(from: "abc", to: "abd") == TextDiff(backspaces: 1, insert: "d"))
    }

    @Test func reconcileFullReplace() {
        #expect(reconcile(from: "abc", to: "xyz") == TextDiff(backspaces: 3, insert: "xyz"))
    }

    @Test func reconcileEmptyOld() {
        #expect(reconcile(from: "", to: "new") == TextDiff(backspaces: 0, insert: "new"))
    }

    @Test func reconcileEmptyNew() {
        #expect(reconcile(from: "old", to: "") == TextDiff(backspaces: 3, insert: ""))
    }

    @Test func reconcileIdentical() {
        #expect(reconcile(from: "same", to: "same") == TextDiff(backspaces: 0, insert: ""))
    }

    @Test func lcpOfArray() {
        #expect(longestCommonPrefix(of: ["I want to", "I wanted to"]) == "I want")
    }

    @Test func trimDropsTrailingPartialWord() {
        #expect(trimToLastWordBoundary("I wanted to") == "I wanted ")
        #expect(trimToLastWordBoundary("hello") == "")
        #expect(trimToLastWordBoundary("") == "")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TranscriptReconcileTests`
Expected: FAIL — build error, `reconcile`/`TextDiff` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// TranscriptReconcile.swift
public struct TextDiff: Equatable, Sendable {
    public let backspaces: Int
    public let insert: String
    public init(backspaces: Int, insert: String) {
        self.backspaces = backspaces
        self.insert = insert
    }
}

/// Minimal edit from `old` to `new`: delete `backspaces` trailing characters of
/// `old`, then type `insert`. Based on the longest common (grapheme) prefix.
public func reconcile(from old: String, to new: String) -> TextDiff {
    let oc = Array(old), nc = Array(new)
    var i = 0
    while i < oc.count, i < nc.count, oc[i] == nc[i] { i += 1 }
    return TextDiff(backspaces: oc.count - i, insert: String(nc[i...]))
}

/// Result of applying one commit/hypothesis update through an insertion strategy.
public enum InsertionResult: Equatable, Sendable {
    case appended(chars: Int)
    case revised(backspaces: Int, inserted: Int)
    case revisionMiss
    case noop
}

func longestCommonPrefix(_ a: String, _ b: String) -> String {
    let ac = Array(a), bc = Array(b)
    var i = 0
    while i < ac.count, i < bc.count, ac[i] == bc[i] { i += 1 }
    return String(ac[0..<i])
}

func longestCommonPrefix(of strings: [String]) -> String {
    guard var prefix = strings.first else { return "" }
    for s in strings.dropFirst() {
        prefix = longestCommonPrefix(prefix, s)
        if prefix.isEmpty { break }
    }
    return prefix
}

/// Prefix up to and including the last whitespace, so only whole words are
/// committed. Returns "" when there is no whitespace (don't commit a partial word).
func trimToLastWordBoundary(_ s: String) -> String {
    guard let idx = s.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return "" }
    return String(s[...idx])
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TranscriptReconcileTests`
Expected: PASS (all 8 tests in the suite).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/TranscriptReconcile.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/TranscriptReconcileTests.swift
git commit -m "feat(dictation): add transcript reconcile + diff primitives"
```

---

## Task 2: Simulated transcript model + fixtures (DictationCore)

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/StreamingTranscript.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/StreamingTranscriptTests.swift`

**Interfaces:**
- Produces: `public enum ScriptKind: Equatable, Sendable, Codable { case partial(String); case final(String) }`; `public struct ScriptEvent: Equatable, Sendable, Codable { public let delayMs: Int; public let kind: ScriptKind }`; `public struct SimulatedTranscriptScript: Equatable, Sendable, Codable { public let name: String; public let events: [ScriptEvent] }` with `static let revisableSample` and `static let immutableSample`.

> Note: fixtures are Swift literals (hand-authored, deterministic). The types are `Codable`, so JSON fixtures remain possible later without code change — this avoids Package.swift resource plumbing for the spike.

- [ ] **Step 1: Write the failing tests**

```swift
// StreamingTranscriptTests.swift
import Foundation
import Testing
@testable import DictationCore

@Suite struct StreamingTranscriptTests {
    @Test func scriptCodableRoundTrip() throws {
        let script = SimulatedTranscriptScript(name: "t", events: [
            .init(delayMs: 10, kind: .partial("a")),
            .init(delayMs: 20, kind: .final("a.")),
        ])
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(SimulatedTranscriptScript.self, from: data)
        #expect(decoded == script)
    }

    @Test func revisableFixtureHasMidUtteranceRevision() {
        // Some partial revises a word that an earlier partial had as a stable prefix.
        let texts = SimulatedTranscriptScript.revisableSample.events.compactMap { ev -> String? in
            if case .partial(let t) = ev.kind { return t } else { return nil }
        }
        // Later partial is NOT a prefix-extension of an earlier one (a real revision).
        let revised = zip(texts, texts.dropFirst()).contains { !$0.1.hasPrefix($0.0) }
        #expect(revised)
    }

    @Test func immutableFixtureIsMonotonic() {
        let texts = SimulatedTranscriptScript.immutableSample.events.compactMap { ev -> String? in
            if case .partial(let t) = ev.kind { return t } else { return nil }
        }
        let monotonic = zip(texts, texts.dropFirst()).allSatisfy { $0.1.hasPrefix($0.0) }
        #expect(monotonic)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter StreamingTranscriptTests`
Expected: FAIL — build error, `SimulatedTranscriptScript` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// StreamingTranscript.swift
public enum ScriptKind: Equatable, Sendable, Codable {
    case partial(String)
    case final(String)
}

public struct ScriptEvent: Equatable, Sendable, Codable {
    public let delayMs: Int
    public let kind: ScriptKind
    public init(delayMs: Int, kind: ScriptKind) {
        self.delayMs = delayMs
        self.kind = kind
    }
}

public struct SimulatedTranscriptScript: Equatable, Sendable, Codable {
    public let name: String
    public let events: [ScriptEvent]
    public init(name: String, events: [ScriptEvent]) {
        self.name = name
        self.events = events
    }
}

public extension SimulatedTranscriptScript {
    /// A revising-tail utterance: "think" becomes "thought" *after* it would have
    /// been committed at a low stability window — the hard case the strategies diverge on.
    static let revisableSample = SimulatedTranscriptScript(name: "revisable", events: [
        .init(delayMs: 120, kind: .partial("I think")),
        .init(delayMs: 120, kind: .partial("I think it")),
        .init(delayMs: 120, kind: .partial("I think it is")),
        .init(delayMs: 120, kind: .partial("I thought it is")),
        .init(delayMs: 120, kind: .partial("I thought it is fine")),
        .init(delayMs: 200, kind: .final("I thought it is fine.")),
    ])

    /// Monotonic growth — each partial extends the previous; no revision.
    static let immutableSample = SimulatedTranscriptScript(name: "immutable", events: [
        .init(delayMs: 120, kind: .partial("the")),
        .init(delayMs: 120, kind: .partial("the quick")),
        .init(delayMs: 120, kind: .partial("the quick brown")),
        .init(delayMs: 120, kind: .partial("the quick brown fox")),
        .init(delayMs: 200, kind: .final("the quick brown fox.")),
    ])
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter StreamingTranscriptTests`
Expected: PASS (all 3 tests in the suite).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/StreamingTranscript.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/StreamingTranscriptTests.swift
git commit -m "feat(dictation): add simulated transcript model + fixtures"
```

---

## Task 3: CommitController (DictationCore)

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/CommitController.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/CommitControllerTests.swift`

**Interfaces:**
- Consumes: `longestCommonPrefix(of:)`, `trimToLastWordBoundary(_:)` (Task 1).
- Produces: `public struct CommitController: Sendable` with `init(stabilityCount: Int = 2)`, `mutating func update(partial: String)`, `mutating func finalize(_ text: String)`, and read-only `committed: String`, `volatileTail: String`, `fullHypothesis: String`.

Semantics: `committed` = finalized text + the longest stable, word-boundary-trimmed prefix of the current segment (stable = longest common prefix across the last `stabilityCount` partials). `volatileTail` = current partial after the committed segment portion. `fullHypothesis` = finalized text + the latest raw partial. Committed text MAY shrink mid-segment when a late partial revises an already-committed word — that's the case the strategies are compared on.

- [ ] **Step 1: Write the failing tests**

```swift
// CommitControllerTests.swift
import Testing
@testable import DictationCore

@Suite struct CommitControllerTests {
    @Test func belowWindowCommitsNothing() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "hello")
        #expect(c.committed == "")
        #expect(c.volatileTail == "hello")
        #expect(c.fullHypothesis == "hello")
    }

    @Test func commitsStableWordBoundaryPrefix() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "the qu")
        c.update(partial: "the quick")        // LCP "the qu" -> trim "the "
        #expect(c.committed == "the ")
        #expect(c.volatileTail == "quick")
    }

    @Test func noCommittedChurnWhenRevisionStaysInVolatile() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "I want")
        c.update(partial: "I want to")        // commits "I "
        c.update(partial: "I wanted to")      // "want"->"wanted" but still volatile
        #expect(c.committed == "I ")
    }

    @Test func committedShrinksOnLateRevision() {
        var c = CommitController(stabilityCount: 2)
        c.update(partial: "I think")
        c.update(partial: "I think it")       // commits "I "
        c.update(partial: "I think it is")    // commits "I think "
        #expect(c.committed == "I think ")
        c.update(partial: "I thought it is")  // think->thought AFTER commit
        #expect(c.committed == "I ")          // committed shrank (hard case)
    }

    @Test func finalizeAccumulatesAcrossSegments() {
        var c = CommitController(stabilityCount: 2)
        c.finalize("Hello.")
        #expect(c.committed == "Hello.")
        #expect(c.volatileTail == "")
        c.update(partial: " world")
        c.finalize(" world wide.")
        #expect(c.committed == "Hello. world wide.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter CommitControllerTests`
Expected: FAIL — build error, `CommitController` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// CommitController.swift
/// Stabilizes a stream of revising partials into a growing committed prefix plus a
/// volatile tail. Pure and synchronous; the replay timeline lives in the source.
public struct CommitController: Sendable {
    public let stabilityCount: Int
    public private(set) var committed = ""
    public private(set) var volatileTail = ""
    public private(set) var fullHypothesis = ""

    private var finalizedText = ""
    private var recentPartials: [String] = []
    private var segmentCommitted = ""

    public init(stabilityCount: Int = 2) {
        self.stabilityCount = max(1, stabilityCount)
    }

    public mutating func update(partial: String) {
        recentPartials.append(partial)
        if recentPartials.count > stabilityCount { recentPartials.removeFirst() }

        let stable = recentPartials.count == stabilityCount
            ? longestCommonPrefix(of: recentPartials)
            : segmentCommitted
        // `stable` is always a prefix of `partial` (it includes `partial` in its LCP
        // once the window is full; before that, segmentCommitted is still "").
        segmentCommitted = trimToLastWordBoundary(stable)

        committed = finalizedText + segmentCommitted
        volatileTail = String(partial.dropFirst(segmentCommitted.count))
        fullHypothesis = finalizedText + partial
    }

    public mutating func finalize(_ text: String) {
        finalizedText += text
        committed = finalizedText
        fullHypothesis = finalizedText
        volatileTail = ""
        segmentCommitted = ""
        recentPartials = []
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter CommitControllerTests`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/CommitController.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/CommitControllerTests.swift
git commit -m "feat(dictation): add CommitController stability window"
```

---

## Task 4: SimulatedTranscriptSource (DictationCore)

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/SimulatedTranscriptSource.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/SimulatedTranscriptSourceTests.swift`

**Interfaces:**
- Consumes: `SimulatedTranscriptScript`, `ScriptKind` (Task 2); the existing `DictationTranscriber` protocol (`transcribe(audioFile:onPartial:onFinal:) async throws`).
- Produces: `public struct SimulatedTranscriptSource: DictationTranscriber` with `init(script: SimulatedTranscriptScript, sleep: @escaping @Sendable (UInt64) async -> Void = …)`.

- [ ] **Step 1: Write the failing test**

```swift
// SimulatedTranscriptSourceTests.swift
import Foundation
import Testing
@testable import DictationCore

@Suite struct SimulatedTranscriptSourceTests {
    @Test func replaysEventsInOrderWithInstantClock() async throws {
        let script = SimulatedTranscriptScript(name: "t", events: [
            .init(delayMs: 999, kind: .partial("a")),
            .init(delayMs: 999, kind: .partial("ab")),
            .init(delayMs: 999, kind: .final("ab.")),
        ])
        let source = SimulatedTranscriptSource(script: script, sleep: { _ in })  // instant

        let (stream, cont) = AsyncStream<String>.makeStream()
        try await source.transcribe(
            audioFile: URL(fileURLWithPath: "/dev/null"),
            onPartial: { cont.yield("P:" + $0) },
            onFinal: { cont.yield("F:" + $0) }
        )
        cont.finish()

        var got: [String] = []
        for await s in stream { got.append(s) }
        #expect(got == ["P:a", "P:ab", "F:ab."])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SimulatedTranscriptSourceTests`
Expected: FAIL — build error, `SimulatedTranscriptSource` undefined.

- [ ] **Step 3: Write the implementation**

```swift
// SimulatedTranscriptSource.swift
import Foundation

/// A `DictationTranscriber` that ignores audio and replays a hand-authored script,
/// honoring per-event delays. Sleep is injected so tests run instantly.
public struct SimulatedTranscriptSource: DictationTranscriber {
    public let script: SimulatedTranscriptScript
    public let sleep: @Sendable (UInt64) async -> Void

    public init(
        script: SimulatedTranscriptScript,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.script = script
        self.sleep = sleep
    }

    public func transcribe(
        audioFile: URL,
        onPartial: @Sendable (String) -> Void,
        onFinal: @Sendable (String) -> Void
    ) async throws {
        for event in script.events {
            await sleep(UInt64(max(0, event.delayMs)) * 1_000_000)
            switch event.kind {
            case .partial(let t): onPartial(t)
            case .final(let t): onFinal(t)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes; then run the whole DictationCore suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SimulatedTranscriptSourceTests`
Expected: PASS.
Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — all suites green (new + pre-existing).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/SimulatedTranscriptSource.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/SimulatedTranscriptSourceTests.swift
git commit -m "feat(dictation): add SimulatedTranscriptSource replay engine"
```

---

## Task 5: InsertionStrategy + ClipboardAppendInserter (app target)

**Files:**
- Create: `Amanuensis/Dictation/Streaming/InsertionStrategy.swift`
- Create: `Amanuensis/Dictation/Streaming/ClipboardAppendInserter.swift`

**Interfaces:**
- Consumes: `reconcile`, `TextDiff`, `InsertionResult` (Task 1); `TextInserter` (existing), `InsertMode.autoInsert` (existing).
- Produces: `protocol InsertionStrategy: AnyObject { func apply(committed: String, fullHypothesis: String) -> InsertionResult; func reset() }`; `final class ClipboardAppendInserter: InsertionStrategy` with `init(paste: @escaping (String) -> Void = …)`.

> The strategy decision is entirely derived from `reconcile` (Task 1, SPM-tested). The side effect (`paste`) is injected so the class is constructed testably; the default wires the real `TextInserter`. Append-only consumes `committed` (the stabilized text).

- [ ] **Step 1: Write the protocol**

```swift
// InsertionStrategy.swift
import DictationCore

/// Strategy for reflecting transcript state into the frontmost app.
/// `committed` is stabilized text; `fullHypothesis` is the full evolving text.
protocol InsertionStrategy: AnyObject {
    func apply(committed: String, fullHypothesis: String) -> InsertionResult
    func reset()
}
```

- [ ] **Step 2: Write the ClipboardAppendInserter**

```swift
// ClipboardAppendInserter.swift
import DictationCore

/// Append-only: pastes newly-stabilized text via ⌘V. Cannot revise already-pasted
/// text — if committed text changes, it records a revision-miss instead.
final class ClipboardAppendInserter: InsertionStrategy {
    private var applied = ""
    private let paste: (String) -> Void

    init(paste: @escaping (String) -> Void = { text in
        _ = TextInserter().insert(text, mode: .autoInsert)
    }) {
        self.paste = paste
    }

    func apply(committed: String, fullHypothesis: String) -> InsertionResult {
        let diff = reconcile(from: applied, to: committed)
        if diff.backspaces > 0 { return .revisionMiss }   // can't unpaste
        guard !diff.insert.isEmpty else { return .noop }
        paste(diff.insert)
        applied = committed
        return .appended(chars: diff.insert.count)
    }

    func reset() { applied = "" }
}
```

- [ ] **Step 3: Verify the app still builds**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED. (Read the build log; fix any compile errors before committing.)

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/Dictation/Streaming/InsertionStrategy.swift \
        Amanuensis/Dictation/Streaming/ClipboardAppendInserter.swift
git commit -m "feat(dictation): add InsertionStrategy + clipboard append inserter"
```

---

## Task 6: KeystrokeDiffInserter (app target)

**Files:**
- Create: `Amanuensis/Dictation/Streaming/KeystrokeDiffInserter.swift`

**Interfaces:**
- Consumes: `reconcile`, `InsertionResult`, `InsertionStrategy` (Tasks 1, 5); `CGEvent`.
- Produces: `final class KeystrokeDiffInserter: InsertionStrategy` with `init(emit: @escaping (Int, String) -> Void = …)`.

> Keystroke consumes `fullHypothesis` (the full evolving text), typing every partial and backspace-correcting the revised tail — the aggressive, minimal-delay extreme. Default `emit` posts real `CGEvent`s (Backspace keycode 51 + `keyboardSetUnicodeString`); injected in tests.

- [ ] **Step 1: Write the implementation**

```swift
// KeystrokeDiffInserter.swift
import AppKit
import CoreGraphics
import DictationCore

/// Types the full evolving hypothesis live, backspacing and retyping the changed
/// tail when a partial revises. Never touches the clipboard.
final class KeystrokeDiffInserter: InsertionStrategy {
    private var applied = ""
    private let emit: (Int, String) -> Void   // (backspaces, insert)

    init(emit: @escaping (Int, String) -> Void = KeystrokeDiffInserter.postEvents) {
        self.emit = emit
    }

    func apply(committed: String, fullHypothesis: String) -> InsertionResult {
        let diff = reconcile(from: applied, to: fullHypothesis)
        if diff.backspaces == 0, diff.insert.isEmpty { return .noop }
        emit(diff.backspaces, diff.insert)
        applied = fullHypothesis
        return diff.backspaces == 0
            ? .appended(chars: diff.insert.count)
            : .revised(backspaces: diff.backspaces, inserted: diff.insert.count)
    }

    func reset() { applied = "" }

    /// Posts `backspaces` Backspace key presses, then types `insert` as a unicode string.
    static func postEvents(backspaces: Int, insert: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 51   // kVK_Delete (Backspace)
        for _ in 0..<backspaces {
            CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true)?
                .post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)?
                .post(tap: .cgSessionEventTap)
        }
        guard !insert.isEmpty else { return }
        var utf16 = Array(insert.utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up?.post(tap: .cgSessionEventTap)
    }
}
```

- [ ] **Step 2: Verify the app still builds**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED. (Read the build log; fix compile errors before committing.)

- [ ] **Step 3: Commit**

```bash
git add Amanuensis/Dictation/Streaming/KeystrokeDiffInserter.swift
git commit -m "feat(dictation): add keystroke + backspace-diff inserter"
```

---

## Task 7: StreamingSpikeHarness + overlay (app target)

**Files:**
- Create: `Amanuensis/Dictation/Streaming/SpikeOverlayPanel.swift`
- Create: `Amanuensis/Dictation/Streaming/StreamingSpikeHarness.swift`

**Interfaces:**
- Consumes: `SimulatedTranscriptSource`, `SimulatedTranscriptScript`, `CommitController`, `InsertionResult` (DictationCore); `InsertionStrategy`, `ClipboardAppendInserter`, `KeystrokeDiffInserter` (Tasks 5–6); `TextInserter.requestPostEventAccess()` (existing).
- Produces: `struct SpikeMetrics`; `final class SpikeOverlayPanel`; `@MainActor final class StreamingSpikeHarness` with `init(script:strategy:stabilityCount:)` and `func run() async`.

> All `#if DEBUG`. The harness consumes events on the MainActor via an `AsyncStream` (FIFO ordering), so even though replay runs in a `Task`, `CommitController` and AppKit are touched only on the MainActor.

- [ ] **Step 1: Write the overlay panel**

```swift
// SpikeOverlayPanel.swift
#if DEBUG
import AppKit

/// Minimal always-on-top panel showing committed text + a dimmed volatile tail.
@MainActor
final class SpikeOverlayPanel {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        label.frame = container.bounds.insetBy(dx: 12, dy: 12)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)
        panel.contentView = container
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 320, y: f.minY + 80))
        }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    func render(committed: String, volatile: String) {
        let s = NSMutableAttributedString(
            string: committed,
            attributes: [.foregroundColor: NSColor.white])
        s.append(NSAttributedString(
            string: volatile,
            attributes: [.foregroundColor: NSColor.systemYellow.withAlphaComponent(0.7)]))
        label.attributedStringValue = s
    }
}
#endif
```

- [ ] **Step 2: Write the harness**

```swift
// StreamingSpikeHarness.swift
#if DEBUG
import AppKit
import Foundation
import DictationCore
import os

struct SpikeMetrics: CustomStringConvertible {
    var appendedChars = 0
    var revisedEvents = 0
    var backspaces = 0
    var revisionMisses = 0

    mutating func record(_ r: InsertionResult) {
        switch r {
        case .appended(let n): appendedChars += n
        case .revised(let b, let n): revisedEvents += 1; backspaces += b; appendedChars += n
        case .revisionMiss: revisionMisses += 1
        case .noop: break
        }
    }

    var description: String {
        "appendedChars=\(appendedChars) revisedEvents=\(revisedEvents) "
        + "backspaces=\(backspaces) revisionMisses=\(revisionMisses)"
    }
}

/// DEBUG-only driver: replays a script through the commit window into the frontmost
/// app via a chosen strategy, showing the volatile tail in an overlay and logging metrics.
@MainActor
final class StreamingSpikeHarness {
    private let script: SimulatedTranscriptScript
    private let strategy: InsertionStrategy
    private let stabilityCount: Int
    private let overlay = SpikeOverlayPanel()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "spike")

    init(script: SimulatedTranscriptScript, strategy: InsertionStrategy, stabilityCount: Int = 2) {
        self.script = script
        self.strategy = strategy
        self.stabilityCount = stabilityCount
    }

    func run() async {
        _ = TextInserter.requestPostEventAccess()
        overlay.show()
        strategy.reset()
        var commit = CommitController(stabilityCount: stabilityCount)
        var metrics = SpikeMetrics()

        // Countdown so the developer can focus a target app (e.g. TextEdit).
        for n in stride(from: 3, through: 1, by: -1) {
            overlay.render(committed: "", volatile: "Starting in \(n)…")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let start = Date()
        var firstWordAt: TimeInterval?

        let source = SimulatedTranscriptSource(script: script)
        let (stream, cont) = AsyncStream<ScriptKind>.makeStream()
        let task = Task.detached {
            try? await source.transcribe(
                audioFile: URL(fileURLWithPath: "/dev/null"),
                onPartial: { cont.yield(.partial($0)) },
                onFinal: { cont.yield(.final($0)) })
            cont.finish()
        }

        for await kind in stream {           // consumed on MainActor, in order
            switch kind {
            case .partial(let t): commit.update(partial: t)
            case .final(let t): commit.finalize(t)
            }
            // Idempotent: each strategy diffs against its own last-applied target, so
            // calling once per event is correct for both clipboard and keystroke.
            let result = strategy.apply(
                committed: commit.committed, fullHypothesis: commit.fullHypothesis)
            if firstWordAt == nil, case .appended = result {
                firstWordAt = Date().timeIntervalSince(start)
            }
            metrics.record(result)
            overlay.render(committed: commit.committed, volatile: commit.volatileTail)
        }
        _ = await task.value

        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        let firstMs = firstWordAt.map { Int($0 * 1000) } ?? -1
        log.info("""
            spike[\(self.script.name, privacy: .public) k=\(self.stabilityCount)] \
            \(metrics.description, privacy: .public) \
            firstWordMs=\(firstMs, privacy: .public) totalMs=\(totalMs, privacy: .public)
            """)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        overlay.hide()
    }
}
#endif
```

- [ ] **Step 3: Verify the app still builds**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED. (Read the build log; fix compile errors before committing.)

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/Dictation/Streaming/SpikeOverlayPanel.swift \
        Amanuensis/Dictation/Streaming/StreamingSpikeHarness.swift
git commit -m "feat(dictation): add streaming spike harness + overlay"
```

---

## Task 8: DEBUG menu wiring + manual end-to-end verification

**Files:**
- Modify: `Amanuensis/AmanuensisApp.swift` (add a `#if DEBUG` `CommandMenu`)

**Interfaces:**
- Consumes: `StreamingSpikeHarness`, `ClipboardAppendInserter`, `KeystrokeDiffInserter`, `SimulatedTranscriptScript` (Tasks 2, 5–7).

- [ ] **Step 1: Add the Debug menu to the app's commands**

In `Amanuensis/AmanuensisApp.swift`, add a `.commands` entry after the existing `CommandGroup(replacing: .newItem)` block (inside the same `.commands { … }`):

```swift
#if DEBUG
            CommandMenu("Streaming Spike") {
                StreamingSpikeCommands()
            }
#endif
```

Then add this view at the bottom of the file:

```swift
#if DEBUG
private struct StreamingSpikeCommands: View {
    var body: some View {
        Button("Revisable × Clipboard (k=2)") {
            launch(.revisableSample, ClipboardAppendInserter(), k: 2)
        }
        Button("Revisable × Keystroke (k=2)") {
            launch(.revisableSample, KeystrokeDiffInserter(), k: 2)
        }
        Button("Revisable × Clipboard (k=3)") {
            launch(.revisableSample, ClipboardAppendInserter(), k: 3)
        }
        Button("Immutable × Clipboard (k=2)") {
            launch(.immutableSample, ClipboardAppendInserter(), k: 2)
        }
        Button("Immutable × Keystroke (k=2)") {
            launch(.immutableSample, KeystrokeDiffInserter(), k: 2)
        }
    }

    private func launch(_ script: SimulatedTranscriptScript, _ strategy: InsertionStrategy, k: Int) {
        let harness = StreamingSpikeHarness(script: script, strategy: strategy, stabilityCount: k)
        Task { await harness.run() }   // harness retained by the task until run() completes
    }
}
#endif
```

Ensure `import DictationCore` is present at the top of `AmanuensisApp.swift` (add it if missing — `SimulatedTranscriptScript` lives there).

- [ ] **Step 2: Verify the app builds**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual end-to-end verification (the actual spike)**

Launch the built app, open **TextEdit** with an empty document, then for each menu item under **Streaming Spike**:
1. Choose the menu item, click into the TextEdit document within the 3-second countdown.
2. Observe: the overlay shows the committed text + dimmed volatile tail; committed text appears in TextEdit.
3. Note from Console (`log stream` / the `spike` category, or `./scripts/log-helper.sh show --last 2m --info --predicate 'category == "spike"'`) the metrics line.

Expected observations (the go/no-go evidence):
- **Revisable × Clipboard (k=2):** the "think→thought" revision is dropped — `revisionMisses > 0`, TextEdit ends up wrong ("I think…"). Demonstrates append-only's failure when the commit window is too eager.
- **Revisable × Clipboard (k=3):** larger window avoids the bad commit — `revisionMisses == 0`, correct final text, but words appear later (more lag).
- **Revisable × Keystroke (k=2):** correct final text via backspacing — `backspaces > 0` (visible flicker), `revisionMisses == 0`.
- **Immutable × \*:** clean for both strategies (`revisionMisses == 0`, minimal/zero backspaces).

- [ ] **Step 4: Record the verdict**

Append a short "Findings" section to the spec file
(`docs/superpowers/specs/2026-06-30-realtime-streaming-asr-commit-window-spike-design.md`):
which strategy felt best, the chosen `stabilityCount`, whether the feature is a go, and any
follow-ups for the provider milestone.

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/AmanuensisApp.swift \
        docs/superpowers/specs/2026-06-30-realtime-streaming-asr-commit-window-spike-design.md
git commit -m "feat(dictation): wire DEBUG streaming-spike menu + record findings"
```

---

## Final verification

- [ ] Run the full SPM suite: `swift test --disable-sandbox --package-path Packages/AudioPipeline` — Expected: all green.
- [ ] Build the app: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` — Expected: BUILD SUCCEEDED.
- [ ] The Findings section answers the go/no-go and names the strategy + `stabilityCount` to carry into milestone 2 (real provider).
