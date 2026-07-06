# Parakeet Word Timestamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Parakeet-family models diarized + per-turn-timestamped output by implementing `transcribeTimed(...) -> [TimedWord]` on `FluidAudioEngine`'s Parakeet branch.

**Architecture:** `LocalTranscriptionService.transcribeDiarized` already turns `[TimedWord]` into speaker-labelled, `[mm:ss]`-prefixed output and degrades to plain when an engine throws `.timestampsUnsupported`. Parakeet's `ASRResult.tokenTimings` carries per-token start/end times; a pure `groupParakeetWords` function collapses SentencePiece sub-word tokens into word-level `TimedWord`s, and a shared `runParakeet` helper keeps `transcribe` and `transcribeTimed` running the identical ASR call. No changes to the service, sender, aligner, formatter, or UI.

**Tech Stack:** Swift 6.2, Swift Testing, FluidAudio 0.15.4 (`AsrManager`, `ASRResult`, `TokenTiming`), SPM package `AudioPipeline` → target `LocalTranscription`.

## Global Constraints

- Swift 6.2, strict concurrency. Target `LocalTranscription` uses `nonisolatedSettings` — free functions are `nonisolated` by default (no `@MainActor`); match `attributeSpeakers` in `SpeakerAlignment.swift` (plain `func`, no annotation, callable synchronously from the `FluidAudioEngine`/`LocalTranscriptionService` actors).
- SPM tests: `swift test --disable-sandbox --package-path Packages/AudioPipeline` (the `--disable-sandbox` flag is required in this environment).
- After SPM tests pass, rebuild the app target: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` (`/usr/bin/xcodebuild` self-refuses in-sandbox; the helper routes it through the outside-sandbox daemon).
- `TimedWord.text` convention: each word carries a **single leading space** so `words.map(\.text).joined()` reconstructs correct inter-word spacing (WhisperKit's contract; the leading space on word 1 is trimmed downstream).
- Conventional commits. End commit messages with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- Scope is Parakeet only. SenseVoice/Cohere stay plain via `.timestampsUnsupported`; IndicConformer is deferred.

## File Structure

- **Create** `Packages/AudioPipeline/Sources/LocalTranscription/ParakeetWordGrouping.swift` — the pure `groupParakeetWords([TokenTiming]) -> [TimedWord]` function. Sits beside `SpeakerAlignment.swift`; imports FluidAudio for `TokenTiming`.
- **Modify** `Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift` — extract `runParakeet(...) -> ASRResult`, route the Parakeet branch of `transcribe` through it, add the `transcribeTimed` override.
- **Create** `Packages/AudioPipeline/Tests/LocalTranscriptionTests/ParakeetWordGroupingTests.swift` — deterministic unit tests for the grouping function.
- **Create** `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift` — deterministic test that SenseVoice/Cohere throw `.timestampsUnsupported`, plus the gated real-model E2E.

---

### Task 1: Pure token→word grouping function

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/ParakeetWordGrouping.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/ParakeetWordGroupingTests.swift`

**Interfaces:**
- Consumes: `FluidAudio.TokenTiming` (fields `token: String`, `startTime: TimeInterval`, `endTime: TimeInterval`; public init `TokenTiming(token:tokenId:startTime:endTime:confidence:)`); `TimedWord(text:start:end:)` from `TimedWord.swift`.
- Produces: `func groupParakeetWords(_ timings: [TokenTiming]) -> [TimedWord]` (module-internal, `nonisolated`), consumed by Task 2's `transcribeTimed`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/ParakeetWordGroupingTests.swift`:

```swift
import Testing
import Foundation
import FluidAudio
@testable import LocalTranscription

private func tk(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
    TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1)
}

@Test func groupsSubwordTokensIntoOneWord() {
    let words = groupParakeetWords([tk("▁hel", 0, 0.2), tk("lo", 0.2, 0.4)])
    #expect(words == [TimedWord(text: " hello", start: 0, end: 0.4)])
}

@Test func groupsMultipleWordsSpanningTimes() {
    let words = groupParakeetWords([tk("▁the", 0, 0.1), tk("▁cat", 0.1, 0.3), tk("▁sat", 0.3, 0.5)])
    #expect(words == [
        TimedWord(text: " the", start: 0, end: 0.1),
        TimedWord(text: " cat", start: 0.1, end: 0.3),
        TimedWord(text: " sat", start: 0.3, end: 0.5),
    ])
}

@Test func handlesAsciiSpaceBoundary() {
    let words = groupParakeetWords([tk(" hi", 0, 0.1), tk(" there", 0.1, 0.2)])
    #expect(words.map(\.text) == [" hi", " there"])
}

@Test func skipsSpecialAndEmptyTokens() {
    let words = groupParakeetWords([tk("<blank>", 0, 0), tk("▁ok", 0.1, 0.2), tk("", 0.2, 0.2), tk("<pad>", 0.2, 0.2)])
    #expect(words == [TimedWord(text: " ok", start: 0.1, end: 0.2)])
}

@Test func emptyInputYieldsEmpty() {
    #expect(groupParakeetWords([]).isEmpty)
}

@Test func firstTokenWithoutBoundaryStartsAWord() {   // defensive
    let words = groupParakeetWords([tk("lo", 0, 0.1), tk("▁world", 0.1, 0.3)])
    #expect(words.map(\.text) == [" lo", " world"])
}

@Test func joinedTextReconstructsTranscript() {
    let words = groupParakeetWords([tk("▁the", 0, 0.1), tk("▁cat", 0.1, 0.3)])
    let plain = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    #expect(plain == "the cat")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ParakeetWordGroupingTests`
Expected: FAIL — compile error, `cannot find 'groupParakeetWords' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/AudioPipeline/Sources/LocalTranscription/ParakeetWordGrouping.swift`:

```swift
import Foundation
import FluidAudio

/// Collapse Parakeet's SentencePiece sub-word `TokenTiming`s into word-level `TimedWord`s.
///
/// Parakeet (TDT) emits sub-word tokens (e.g. `▁hel`, `lo`). A token whose text starts with the
/// SentencePiece boundary marker `▁` (U+2581) or an ASCII space begins a new word; other tokens
/// continue the current word. The first non-special token also begins a word. Each emitted word
/// carries a single leading space to match WhisperKit's convention, so the pipeline's
/// `words.map(\.text).joined()` reconstructs the transcript with correct inter-word spacing
/// (the leading space on word 1 is trimmed downstream).
///
/// Returns an empty array when `timings` is empty or holds only special tokens — the caller
/// treats that as "no timestamps available" and degrades to a plain transcript.
func groupParakeetWords(_ timings: [TokenTiming]) -> [TimedWord] {
    var words: [TimedWord] = []
    var current = ""
    var start = 0.0
    var end = 0.0
    var open = false   // whether `current` holds an in-progress word

    func flush() {
        guard open else { return }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            words.append(TimedWord(text: " " + trimmed, start: start, end: end))
        }
        current = ""
        open = false
    }

    for timing in timings {
        let token = timing.token
        if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
        let startsWord = token.hasPrefix("▁") || token.hasPrefix(" ")
        if startsWord || !open {
            flush()
            current = stripWordBoundary(token)
            start = timing.startTime
            open = true
        } else {
            current += token
        }
        end = timing.endTime
    }
    flush()
    return words
}

private func stripWordBoundary(_ token: String) -> String {
    if token.hasPrefix("▁") { return String(token.dropFirst()) }
    return String(token.drop(while: { $0 == " " }))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ParakeetWordGroupingTests`
Expected: PASS — 7 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/ParakeetWordGrouping.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/ParakeetWordGroupingTests.swift
git commit -m "$(cat <<'EOF'
feat(local): token->word grouping for Parakeet timestamps

Collapse SentencePiece sub-word TokenTimings (▁hel, lo) into word-level
TimedWords with WhisperKit's leading-space convention. Empty/specials-only
input yields [], which the engine treats as "no timestamps" -> plain.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `transcribeTimed` on FluidAudioEngine (shared `runParakeet`)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift`

**Interfaces:**
- Consumes: `groupParakeetWords(_:)` (Task 1); FluidAudio `ASRResult.tokenTimings: [TokenTiming]?`; existing `loadParakeetManager`, `parakeetVersion`, `residentModelID`, `resident` on the engine.
- Produces: `func transcribeTimed(audioURL:model:language:) async throws -> [TimedWord]` on `FluidAudioEngine`; private `func runParakeet(audioURL:model:language:) async throws -> ASRResult`.

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift`. These cases short-circuit before any filesystem/model access, so they are deterministic and need no downloaded models:

```swift
import Testing
import Foundation
@testable import LocalTranscription

private func expectTimestampsUnsupported(_ modelID: String) async {
    let engine = FluidAudioEngine()
    let model = LocalModelCatalog.model(id: modelID)!
    do {
        _ = try await engine.transcribeTimed(audioURL: URL(filePath: "/dev/null"), model: model, language: nil)
        Issue.record("expected transcribeTimed to throw for \(modelID)")
    } catch let error as LocalTranscriptionError {
        guard case .timestampsUnsupported = error else {
            Issue.record("expected .timestampsUnsupported for \(modelID), got \(error)")
            return
        }
    } catch {
        Issue.record("unexpected error type for \(modelID): \(error)")
    }
}

@Test func senseVoiceTranscribeTimedThrowsUnsupported() async {
    await expectTimestampsUnsupported("sensevoice-small")
}

@Test func cohereTranscribeTimedThrowsUnsupported() async {
    await expectTimestampsUnsupported("cohere-transcribe")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FluidAudioEngineTimedTests`
Expected: FAIL — the inherited protocol-default `transcribeTimed` throws `.timestampsUnsupported` too, so these two *may pass by accident today*. To force a real failure first, confirm the file compiles and the tests run; they will pass against the default. **This is expected** — the default already throws unsupported, and Task 2's override must preserve that for SenseVoice/Cohere. Treat Step 4's run (after wiring the override) as the meaningful gate. (If you prefer a strictly-red step, temporarily assert `words.isEmpty == false` and revert after Step 3.)

- [ ] **Step 3: Write the implementation**

In `Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift`:

**(a)** Add the shared helper in the `// MARK: - Load helpers` region (after `loadCohereModels`):

```swift
    /// Run the Parakeet ASR for `model` and return the full `ASRResult`. Shared by
    /// `transcribe` (reads `.text`) and `transcribeTimed` (reads `.tokenTimings`) so the two
    /// never drift. Reuses the resident manager when it's this model; otherwise loads a
    /// transient one and lets it go — the resident slot is untouched.
    private func runParakeet(audioURL: URL, model: LocalModel, language: String?) async throws -> ASRResult {
        let version = parakeetVersion(model.selector)
        let asr: AsrManager
        if model.id == residentModelID, case .parakeet(let cached) = resident {
            asr = cached
        } else {
            asr = try await loadParakeetManager(model)
        }
        // language hint is only honoured by the v3 joint decoder
        let lang: Language? = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
        var state = try TdtDecoderState(decoderLayers: version.decoderLayers)
        return try await asr.transcribe(audioURL, decoderState: &state, language: lang)
    }
```

**(b)** Replace the `.fluidAudioParakeet` branch body inside `transcribe` (currently the block that resolves `asr`, builds `state`, calls `asr.transcribe`, and `return result.text`) with:

```swift
        case .fluidAudioParakeet:
            return try await runParakeet(audioURL: audioURL, model: model, language: language).text
```

**(c)** Add the `transcribeTimed` override as a new method after `transcribe`:

```swift
    public func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] {
        switch model.runner {
        case .fluidAudioParakeet:
            guard await isDownloaded(model) else {
                throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
            }
            let result = try await runParakeet(audioURL: audioURL, model: model, language: language)
            let words = groupParakeetWords(result.tokenTimings ?? [])
            // No timings (some configs return nil) → let the orchestration fall back to plain.
            guard !words.isEmpty else {
                throw LocalTranscriptionError.timestampsUnsupported(model.displayName)
            }
            return words
        default:
            // SenseVoice / Cohere expose no audio timestamps; stay plain.
            throw LocalTranscriptionError.timestampsUnsupported(model.displayName)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FluidAudioEngineTimedTests`
Expected: PASS — 2 tests. (If you added the temporary red assertion in Step 2, revert it first.)

- [ ] **Step 5: Run the full SPM suite and rebuild the app**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — full suite green (the pre-existing count plus the new tests; no regressions in `TranscribeDiarizedTests`, `WhisperKitEngineTests`, etc.).

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `BUILD SUCCEEDED` (confirms the app target still compiles — `swift test` only compiles the SPM package).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift
git commit -m "$(cat <<'EOF'
feat(local): Parakeet transcribeTimed -> diarization + per-turn timestamps

Add transcribeTimed on FluidAudioEngine: the Parakeet branch runs the shared
runParakeet ASR call and maps result.tokenTimings through groupParakeetWords;
empty timings throw .timestampsUnsupported so the orchestration degrades to
plain. SenseVoice/Cohere throw unsupported (no audio-timestamp API). transcribe
now shares runParakeet so text/timed paths can't drift.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Gated real-model E2E

**Files:**
- Modify: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift`

**Interfaces:**
- Consumes: `FluidAudioEngine().transcribeTimed(...)` (Task 2); `LocalModelCatalog.model(id:)`; env var `AMANUENSIS_DIARIZATION_FIXTURE` (a 16 kHz-resamplable audio path, same var the existing `DiarizationE2ETests` uses).
- Produces: nothing consumed downstream — verification only.

- [ ] **Step 1: Add the gated test**

Append to `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift`:

```swift
// Real-model E2E: opt-in via AMANUENSIS_DIARIZATION_FIXTURE (an English audio clip) and a
// downloaded Parakeet model. Silently no-ops when the fixture or models are absent — like the
// other gated E2Es (DiarizationE2ETests). Proves tokenTimings is actually populated per version.
@Test func parakeetVersionsProduceTimedWordsWhenPresent() async throws {
    guard let path = ProcessInfo.processInfo.environment["AMANUENSIS_DIARIZATION_FIXTURE"],
          FileManager.default.fileExists(atPath: path) else { return }
    let engine = FluidAudioEngine()
    // Both versions support English, so the same fixture exercises each. tdtJa needs a Japanese
    // clip and is verified manually.
    for id in ["parakeet-tdt-ctc-110m", "parakeet-tdt-v3"] {
        let model = LocalModelCatalog.model(id: id)!
        guard await engine.isDownloaded(model) else { continue }
        let words = try await engine.transcribeTimed(
            audioURL: URL(filePath: path), model: model, language: "en")
        #expect(!words.isEmpty, "\(id) produced no timed words")
        #expect(words.allSatisfy { $0.end >= $0.start }, "\(id) has a word with end < start")
        #expect(words.allSatisfy { $0.text.hasPrefix(" ") }, "\(id) violated the leading-space convention")
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start }, "\(id) word starts not monotonic")
    }
}
```

- [ ] **Step 2: Run it (no-op path)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FluidAudioEngineTimedTests`
Expected: PASS — with no fixture env var set, the E2E returns early (silent skip); the two unsupported-throw tests still pass.

- [ ] **Step 3: Run it against a real model (manual, optional)**

If a Parakeet model is downloaded in the app's container, point the test at a real clip and the container Models dir (mirrors the `IndicConformerIntegrationTests` recipe in `CLAUDE.local.md`):

```bash
AMANUENSIS_MODELS_DIR="$HOME/Library/Containers/work.miklos.amanuensis/Data/Library/Application Support/Amanuensis/Models" \
AMANUENSIS_DIARIZATION_FIXTURE="/path/to/english-2-speaker-16k.wav" \
  swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FluidAudioEngineTimedTests
```
Expected: PASS with real assertions exercised for each downloaded Parakeet version. If a version comes back with empty words, `tokenTimings` isn't populated for it — capture that in the follow-ups doc.

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Tests/LocalTranscriptionTests/FluidAudioEngineTimedTests.swift
git commit -m "$(cat <<'EOF'
test(local): gated E2E for Parakeet transcribeTimed

Opt-in via AMANUENSIS_DIARIZATION_FIXTURE + a downloaded Parakeet model; silent
no-op otherwise. Asserts timed words are non-empty, ordered, and carry the
leading-space convention for each downloaded version — the empirical check that
tokenTimings is populated.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Spec §1 (engine method, shared `runParakeet`, SenseVoice/Cohere throw) → Task 2. ✓
- Spec §2 (token→word grouping, spacing convention, empty guard) → Task 1 + Task 2's `guard !words.isEmpty`. ✓
- Spec §3 (unit tests + gated E2E) → Task 1 tests + Task 3. ✓
- Spec §4/§5 (risks: tokenTimings optional, fallback fidelity) → handled by the empty-guard degradation (Task 2) and confirmed by Task 3's E2E. ✓
- Spec out-of-scope (IndicConformer, SenseVoice/Cohere timestamps, UI) → not implemented; SenseVoice/Cohere covered by the throw. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code and exact commands. Task 2 Step 2 explains the "already-throws-by-default" nuance honestly rather than faking a red. ✓

**Type consistency:** `groupParakeetWords(_ timings: [TokenTiming]) -> [TimedWord]` defined in Task 1, called identically in Task 2. `runParakeet(audioURL:model:language:) -> ASRResult` defined and called consistently. `TimedWord(text:start:end:)` and `TokenTiming(token:tokenId:startTime:endTime:confidence:)` match their real inits. `.timestampsUnsupported`/`.modelNotDownloaded` match `LocalTranscriptionError`. ✓
