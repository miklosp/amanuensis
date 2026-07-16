# Apple SpeechAnalyzer Local Engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple's macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` as one more on-device model in the existing local catalog, behind the current `LocalTranscriptionEngine` protocol (batch only; streaming deferred).

**Architecture:** A new `@available(macOS 26, *)` engine slots into `LocalTranscriptionService` via a new `.appleSpeech` runner and a catalog row. The service holds the engine as an *optional* (`nil` on macOS < 26). Language assets are Apple-managed per-locale via `AssetInventory`; the Models card gains a per-language installer. Both batch Jobs and dictation-clip transcription light up for free (both route through the service); word timestamps come from `SpeechTranscriber.Result`, so the diarized path works.

**Tech Stack:** Swift 6.2, Speech framework (macOS 26), AVFoundation (`AVAudioFile`), CoreMedia (`CMTimeRange`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-16-apple-speech-local-engine-design.md`

## Global Constraints

- **Deployment target macOS 14.4; Speech API used here is macOS 26.0+.** Every use of `SpeechAnalyzer`/`SpeechTranscriber`/`AssetInventory` lives inside `@available(macOS 26, *)` types or `if #available(macOS 26, *)` blocks. `import Speech` at file scope is fine (only the new symbols are gated).
- **Default actor isolation is `MainActor`** in this project. The engine does off-main work → declare it `public actor AppleSpeechEngine` (mirror `WhisperKitEngine`).
- **Swift 6.2 strict concurrency** (`SWIFT_APPROACHABLE_CONCURRENCY = YES`). No data races; keep engine state actor-isolated.
- **Keep Parakeet TDT-CTC 110M the recommended English default.** The new row is `recommended: false`.
- **SPM tests:** `swift test --disable-sandbox --package-path Packages/AudioPipeline`. **After SPM green, rebuild the app target** via the xcode-build skill: `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`.
- **Real model/asset e2e cannot run in the Claude Code sandbox** (asset dirs + `SpeechTranscriber.isAvailable` need the system). Anything touching the live model is a `@available`-gated, skip-when-unavailable integration test, run via the xcode-build daemon (host is macOS 26.3) or in-app.
- **Conventional commits**; end every commit message with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Work on branch `feat/apple-speech-local-engine` (already created; spec already committed there).

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift` | `.appleSpeech` runner, catalog row, `isAvailableOnThisOS`/`available` | 1 |
| `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift` | new `requiresNewerOS` error case | 1 |
| `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift` | optional `appleSpeech` engine + `resolve` case | 1 |
| `Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift` | **new** — the engine (asset mgmt + transcription) | 2, 3 |
| `Amanuensis/AppCoordinator.swift` | construct engine gated, pass to service | 2 |
| `Amanuensis/UI/Models/ModelsView.swift` | list `available` instead of `all` | 4 |
| `Amanuensis/UI/Models/ModelCardView.swift` | "System" size text; per-language installer | 4, 5 |
| `Packages/AudioPipeline/Sources/LocalTranscription/LocalModelsStore.swift` | per-locale install state/actions | 5 |
| `Packages/AudioPipeline/Tests/LocalTranscriptionTests/*` | unit + gated integration tests | 1, 3, 6 |

---

### Task 1: Dispatch plumbing — runner, catalog row, service routing

Makes `apple-speech` a dispatchable model routed to an *injected* engine (nil ⇒ a clear "requires macOS 26" error). No real engine yet — proven with `FakeEngine`. Build and all existing tests stay green (the new service param defaults to `nil`, so the six existing service-construction call sites are untouched; only `resolve`'s switch is forced to change).

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift`
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift`
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechDispatchTests.swift` (create)

**Interfaces:**
- Produces: `LocalRunner.appleSpeech`; catalog row id `"apple-speech"`; `LocalModel.isAvailableOnThisOS: Bool`; `LocalModelCatalog.available: [LocalModel]`; `LocalTranscriptionError.requiresNewerOS(String)`; `LocalTranscriptionService.init(..., appleSpeech: (any LocalTranscriptionEngine)? = nil, ...)`.

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechDispatchTests.swift`:

```swift
import Testing
import Foundation
@testable import LocalTranscription

@Suite struct AppleSpeechDispatchTests {
    private func fixtureURL() -> URL { URL(fileURLWithPath: "/dev/null") }

    @Test func catalogHasAppleSpeechRow() {
        let m = LocalModelCatalog.model(id: "apple-speech")
        #expect(m != nil)
        #expect(m?.runner == .appleSpeech)
        #expect(m?.recommended == false)
        #expect(m?.defaultLanguage == nil)
        #expect((m?.supportedLanguages.isEmpty ?? true) == false)
        // Parakeet stays THE recommended default.
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")?.recommended == true)
    }

    @Test func nonAppleModelsAlwaysAvailable() {
        for m in LocalModelCatalog.all where m.runner != .appleSpeech {
            #expect(m.isAvailableOnThisOS)
        }
        #expect(LocalModelCatalog.available.allSatisfy { $0.isAvailableOnThisOS })
    }

    @Test func routesToInjectedAppleEngine() async throws {
        let fake = FakeEngine()
        await fake.setDownloaded(["apple-speech"])
        await fake.setTranscript("apple result")
        let svc = LocalTranscriptionService(
            fluidAudio: FakeEngine(), whisperKit: FakeEngine(),
            indicConformer: FakeEngine(), appleSpeech: fake)
        let text = try await svc.transcribe(audioURL: fixtureURL(), modelID: "apple-speech", language: "en")
        #expect(text == "apple result")
    }

    @Test func missingAppleEngineThrowsRequiresNewerOS() async {
        let svc = LocalTranscriptionService(
            fluidAudio: FakeEngine(), whisperKit: FakeEngine(),
            indicConformer: FakeEngine())   // appleSpeech defaults to nil
        await #expect(throws: LocalTranscriptionError.self) {
            _ = try await svc.transcribe(audioURL: fixtureURL(), modelID: "apple-speech", language: "en")
        }
    }
}
```

This needs two `FakeEngine` helpers that don't exist yet (`setDownloaded`, `setTranscript`). Add them to `FakeEngine.swift`:

```swift
func setDownloaded(_ ids: Set<String>) { downloaded = ids }
func setTranscript(_ t: String) { transcript = t }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppleSpeechDispatchTests`
Expected: FAIL to compile — `.appleSpeech` unknown, `apple-speech` row missing, `appleSpeech:` param missing.

- [ ] **Step 3: Add the runner case + error case**

In `LocalModel.swift`, add to `LocalRunner`:

```swift
    case appleSpeech             // Apple SpeechAnalyzer (macOS 26+); engine is optional on the service
```

In `LocalTranscriptionEngine.swift`, add to `LocalTranscriptionError` and its `errorDescription`:

```swift
    case requiresNewerOS(String)
```
```swift
        case .requiresNewerOS(let n): return "\(n) requires macOS 26 or later."
```

- [ ] **Step 4: Add the catalog row + availability helpers**

In `LocalModel.swift`, append to `LocalModelCatalog.all` (inside the array literal):

```swift
        LocalModel(id: "apple-speech", displayName: "Apple Speech (System)",
                   summary: "Built into macOS 26. No download; Apple-managed languages. Fast, private, on-device.",
                   languages: "~30 languages (system-managed)",
                   supportedLanguages: [
                       "en", "es", "fr", "de", "it", "pt", "zh", "yue", "ja", "ko",
                       "ar", "hi", "ru", "nl", "sv", "da", "nb", "fi", "pl", "tr",
                       "uk", "id", "th", "vi",
                   ],
                   approxBytes: 0,
                   runner: .appleSpeech, selector: "", recommended: false,
                   defaultLanguage: nil),
```

Below the `LocalModel` struct (top level in the file), add:

```swift
public extension LocalModel {
    /// False for a model whose engine needs a newer OS than the running system,
    /// so UI lists can hide it. Non-OS-gated models are always available.
    var isAvailableOnThisOS: Bool {
        switch runner {
        case .appleSpeech:
            if #available(macOS 26, *) { return true } else { return false }
        default:
            return true
        }
    }
}
```

And inside `enum LocalModelCatalog`, add:

```swift
    /// Catalog rows whose engine can actually run on this OS — for UI listing.
    public static var available: [LocalModel] { all.filter(\.isAvailableOnThisOS) }
```

- [ ] **Step 5: Wire the service (optional engine + resolve case)**

In `LocalTranscriptionService.swift`, add the stored property near the others:

```swift
    private let appleSpeech: (any LocalTranscriptionEngine)?
```

Add the parameter to `init` (after `indicConformer:`, before `diarizer:` — all trailing params keep their defaults, so existing call sites compile unchanged):

```swift
        indicConformer: any LocalTranscriptionEngine,
        appleSpeech: (any LocalTranscriptionEngine)? = nil,
        diarizer: any SpeakerDiarizing = FluidAudioDiarizer(),
```

Assign it in the body:

```swift
        self.appleSpeech = appleSpeech
```

Add the case to `resolve` (the switch is now non-exhaustive without it — this is the one forced change):

```swift
        case .appleSpeech:
            guard let e = appleSpeech else { throw LocalTranscriptionError.requiresNewerOS(m.displayName) }
            return (m, e)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppleSpeechDispatchTests`
Expected: PASS (4 tests).

Then the full suite to confirm no regressions:
Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (all existing suites green).

- [ ] **Step 7: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechDispatchTests.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/FakeEngine.swift
git commit -m "feat(local): add apple-speech runner, catalog row, and service routing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: AppleSpeechEngine — asset & locale management

The engine's model-management half: availability, locale resolution, and mapping the `download`/`isDownloaded`/`delete` protocol methods onto `AssetInventory` + `SpeechTranscriber.installedLocales`. Also wire the real engine into `AppCoordinator` (gated), replacing Task 1's implicit `nil`.

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift`
- Modify: `Amanuensis/AppCoordinator.swift`

**Interfaces:**
- Consumes: `LocalTranscriptionEngine`, `LocalModel`, `LocalTranscriptionError` (Task 1).
- Produces: `@available(macOS 26, *) public actor AppleSpeechEngine: LocalTranscriptionEngine`; private helpers `resolveLocale(_ language: String?) async throws -> Locale`, `ensureInstalled(_ locale: Locale) async throws`.

- [ ] **Step 1: Create the engine file with asset/locale methods**

Create `Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift`:

```swift
import Foundation
import Speech
import AVFoundation

/// On-device transcription engine backed by Apple's SpeechAnalyzer (macOS 26+).
///
/// Handles the `.appleSpeech` runner. Unlike the other engines, the model is the OS:
/// there are no downloaded weights on our storage — `SpeechTranscriber` uses per-locale
/// assets that Apple installs and manages via `AssetInventory`. So `download` maps to a
/// locale asset install + reservation, `isDownloaded` to "the resolved locale is
/// installed", `installedBytes` to 0 (no per-locale byte API), and `delete` to releasing
/// our reservation (the shared system asset may persist).
@available(macOS 26, *)
public actor AppleSpeechEngine: LocalTranscriptionEngine {
    public init() {}

    // MARK: - Locale resolution

    /// Map an app language code (2-letter, e.g. "en") or nil to a concrete locale that
    /// SpeechTranscriber supports. An explicit-but-unsupported choice throws (never a
    /// silent wrong-language fallback); nil falls back to the system locale, then en-US.
    func resolveLocale(_ language: String?) async throws -> Locale {
        if let code = language?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code)) {
                return supported
            }
            throw LocalTranscriptionError.transcriptionFailed("Language \"\(code)\" isn't available for Apple Speech.")
        }
        if let sys = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return sys }
        if let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) { return en }
        throw LocalTranscriptionError.transcriptionFailed("No supported Apple Speech locale on this device.")
    }

    /// Install the locale asset if it isn't already, and reserve it so the system won't
    /// reclaim it. `assetInstallationRequest` returns nil when nothing needs installing.
    func ensureInstalled(_ locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        if !installed {
            let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        }
        try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - LocalTranscriptionEngine (asset management)

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        // "Downloaded" == the resolved default locale's asset is installed. transcribe()
        // self-heals for any other requested language, so this is just the baseline signal.
        guard let locale = try? await resolveLocale(model.defaultLanguage) else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 { 0 }  // no per-locale byte API

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard await SpeechTranscriber.isAvailable else {
            throw LocalTranscriptionError.transcriptionFailed("Apple Speech isn't available on this device.")
        }
        let locale = try await resolveLocale(model.defaultLanguage)
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            // Drive coarse progress off the request's Progress. (A KVO/AsyncSequence bridge
            // can refine this later; downloadAndInstall() awaits completion regardless.)
            progress(0)
            try await request.downloadAndInstall()
        }
        try? await AssetInventory.reserve(locale: locale)
        progress(1)
    }

    public func delete(_ model: LocalModel) async throws {
        // We don't force-delete a shared system asset; we relinquish our reservation.
        guard let locale = try? await resolveLocale(model.defaultLanguage) else { return }
        try await AssetInventory.release(reservedLocale: locale)
    }
}
```

> Note for the implementer: confirm the option-set argument labels/case spellings on first compile (`transcriptionOptions`/`reportingOptions`/`attributeOptions` are `OptionSet`s; `AssetInstallationRequest.downloadAndInstall()` and `.progress` per the macOS 26 SDK). The declarations were verified from the docs; the exact `OptionSet` case names (`.audioTimeRange`, etc.) are used in Task 3.

- [ ] **Step 2: Verify the package compiles**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppleSpeechDispatchTests`
Expected: PASS — the new file compiles against the macOS 26 SDK (host is 26.3); existing dispatch tests still green (they use `FakeEngine`, not the real engine).

- [ ] **Step 3: Wire the real engine into AppCoordinator (gated)**

In `Amanuensis/AppCoordinator.swift`, change the service construction (currently three engine args) to pass a gated `appleSpeech`:

```swift
        let appleSpeech: (any LocalTranscriptionEngine)? = {
            if #available(macOS 26, *) { return AppleSpeechEngine() } else { return nil }
        }()
        let localService = LocalTranscriptionService(
            fluidAudio: FluidAudioEngine(),
            whisperKit: WhisperKitEngine(),
            indicConformer: IndicConformerEngine(),
            appleSpeech: appleSpeech)
```

- [ ] **Step 4: Build the app target**

Run (via xcode-build skill): `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift \
        Amanuensis/AppCoordinator.swift
git commit -m "feat(local): AppleSpeechEngine asset/locale management + wiring

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: AppleSpeechEngine — transcription + word timings

The engine's transcription half: run `SpeechAnalyzer` over a file, drain results, and extract `[TimedWord]` from the result `AttributedString`'s time-range attribute. The timing-extraction helper is pure and unit-tested; the full transcribe path is verified by the Task 6 integration test.

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechTimingsTests.swift` (create)

**Interfaces:**
- Consumes: `AppleSpeechEngine` (Task 2), `TimedWord`.
- Produces: `func timedWords(from text: AttributedString) -> [TimedWord]`; `transcribe`, `transcribeTimed`, `preload`, `unloadResident` on the engine.

- [ ] **Step 1: Write the failing test for timing extraction**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechTimingsTests.swift`:

```swift
import Testing
import Foundation
import CoreMedia
@testable import LocalTranscription

@available(macOS 26, *)
@Suite struct AppleSpeechTimingsTests {
    /// Build an AttributedString whose runs carry the Speech time-range attribute,
    /// mimicking what SpeechTranscriber.Result.text yields.
    private func timed(_ word: String, _ start: Double, _ end: Double) -> AttributedString {
        var s = AttributedString(word)
        s.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1000),
            end: CMTime(seconds: end, preferredTimescale: 1000))
        return s
    }

    @Test func extractsWordsWithSeconds() {
        var text = timed("Hello ", 0.0, 0.5)
        text.append(timed("world", 0.5, 1.0))
        let words = AppleSpeechEngine.timedWords(from: text)
        #expect(words.count == 2)
        #expect(words[0].text == "Hello ")
        #expect(abs(words[0].start - 0.0) < 0.001)
        #expect(abs(words[0].end - 0.5) < 0.001)
        #expect(words[1].text == "world")
        #expect(abs(words[1].start - 0.5) < 0.001)
    }

    @Test func skipsRunsWithoutTimeRange() {
        var text = AttributedString("untimed ")   // no attribute
        text.append(timed("timed", 1.0, 1.5))
        let words = AppleSpeechEngine.timedWords(from: text)
        #expect(words.count == 1)
        #expect(words[0].text == "timed")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppleSpeechTimingsTests`
Expected: FAIL to compile — `AppleSpeechEngine.timedWords(from:)` doesn't exist.

- [ ] **Step 3: Add the pure timing-extraction helper**

Append to `AppleSpeechEngine.swift`, inside the `@available(macOS 26, *)` scope but as a `nonisolated static` so tests call it without the actor and it stays pure:

```swift
@available(macOS 26, *)
public extension AppleSpeechEngine {
    /// Extract per-run words + seconds from a transcription's AttributedString. Each run
    /// that carries the Speech time-range attribute becomes one `TimedWord`; untimed runs
    /// (rare, e.g. joins) are skipped. `text[run.range]` is the run's substring.
    nonisolated static func timedWords(from text: AttributedString) -> [TimedWord] {
        var out: [TimedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            out.append(TimedWord(
                text: piece,
                start: CMTimeGetSeconds(range.start),
                end: CMTimeGetSeconds(range.end)))
        }
        return out
    }
}
```

> `run.audioTimeRange` is the `AttributeScopes.SpeechAttributes` time-range attribute accessor. If the dynamic-member spelling differs in the SDK, read it explicitly via `run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]`. Confirm at compile.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppleSpeechTimingsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Add transcribe / transcribeTimed / preload / unloadResident**

Append to `AppleSpeechEngine.swift` (inside the actor):

```swift
    // MARK: - LocalTranscriptionEngine (transcription)

    /// One batch run: build a transcriber for `locale` (optionally with word time ranges),
    /// feed the whole file through a fresh analyzer, and collect finalized results.
    /// Returns the concatenated AttributedString so callers derive plain text or timings.
    private func runAnalyzer(audioURL: URL, locale: Locale, timed: Bool) async throws -> AttributedString {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],                        // batch: final results only
            attributeOptions: timed ? [.audioTimeRange] : [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audioURL)

        let collector = Task {
            var acc = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                acc.append(result.text)
            }
            return acc
        }
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw LocalTranscriptionError.transcriptionFailed(error.localizedDescription)
        }
        return try await collector.value
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        let locale = try await resolveLocale(language)
        try await ensureInstalled(locale)
        let acc = try await runAnalyzer(audioURL: audioURL, locale: locale, timed: false)
        return String(acc.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] {
        let locale = try await resolveLocale(language)
        try await ensureInstalled(locale)
        let acc = try await runAnalyzer(audioURL: audioURL, locale: locale, timed: true)
        let words = Self.timedWords(from: acc)
        if words.isEmpty {
            // Text but no timings → let the diarized path degrade to plain, no second pass.
            throw LocalTranscriptionError.timingsUnavailable(
                plainText: String(acc.characters).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return words
    }

    public func preload(_ model: LocalModel) async throws {
        // Warm the locale asset so the first real transcription doesn't pay install latency.
        let locale = try await resolveLocale(model.defaultLanguage)
        try await ensureInstalled(locale)
    }

    public func unloadResident() async {}   // nothing retained between runs
```

- [ ] **Step 6: Verify build + full suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (all suites, including the two new ones).
Then: `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechTimingsTests.swift
git commit -m "feat(local): AppleSpeechEngine batch transcription + word timings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Models page — availability filter + "System" label

Make the Apple Speech row appear correctly: shown only on macOS 26, with "System" where other cards show a download size. This is the minimal working UI — Download at this point installs the default (system-preferred) locale via the engine; the richer per-language installer is Task 5.

**Files:**
- Modify: `Amanuensis/UI/Models/ModelsView.swift`
- Modify: `Amanuensis/UI/Models/ModelCardView.swift`

**Interfaces:**
- Consumes: `LocalModelCatalog.available` (Task 1), the `apple-speech` row.

- [ ] **Step 1: List `available` instead of `all`**

In `ModelsView.swift`, change the loop source:

```swift
                ForEach(LocalModelCatalog.available) { model in
```

- [ ] **Step 2: Show "System" instead of a byte size for the row**

In `ModelCardView.swift`, change `sizeText` so a zero-`approxBytes` system model reads "System":

```swift
    private var sizeText: String {
        if model.approxBytes == 0 && !state.isDownloaded { return "System" }
        return state.isDownloaded ? fmt(state.installedBytes) : "~\(fmt(model.approxBytes))"
    }
```

- [ ] **Step 3: Build the app target**

Run: `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual check (macOS 26 host)**

Launch the app → Settings → Local Models. Expected: an "Apple Speech (System)" card appears, subtitle shows "System · ~30 languages (system-managed)", with a Download button. (Full transcription verified in Task 6.)

- [ ] **Step 5: Commit**

```bash
git add Amanuensis/UI/Models/ModelsView.swift Amanuensis/UI/Models/ModelCardView.swift
git commit -m "feat(local): show Apple Speech card (macOS 26 only) with System size label

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Per-language installer UI

Replace the Apple Speech card's read-only language chips with an interactive installer: show `SpeechTranscriber.supportedLocales`, mark installed ones, pre-check the system-preferred set, and let the user check/uncheck to install (`assetInstallationRequest` + `reserve`) or release (`release(reservedLocale:)`). Respect `AssetInventory.maximumReservedLocales`.

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift` (expose locale-listing/install/release for a set)
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModelsStore.swift` (per-locale state + actions)
- Modify: `Amanuensis/UI/Models/ModelCardView.swift` (installer view for `.appleSpeech`)

**Interfaces:**
- Produces on the engine: `nonisolated func availableLocaleCodes() async -> [String]`, `func installedLocaleCodes() async -> [String]`, `func install(localeCode: String, progress:) async throws`, `func release(localeCode: String) async throws`, `func maxReservedLocales() async -> Int`, `func systemPreferredCodes() async -> [String]`.
- Produces on the store: `AppleSpeechLocaleState` (installed set, in-flight set) + `func refreshAppleLocales()`, `func toggleAppleLocale(_ code: String, install: Bool)`.

- [ ] **Step 1: Expose locale operations on the engine**

Append to `AppleSpeechEngine.swift` (inside the actor). These project `Locale` to the app's 2-letter codes (matching the catalog's `supportedLanguages`) so the UI speaks one vocabulary:

```swift
    // MARK: - Per-language installer support

    /// App-facing 2-letter codes the OS supports (deduped from SpeechTranscriber.supportedLocales).
    func availableLocaleCodes() async -> [String] {
        let locales = await SpeechTranscriber.supportedLocales
        return Array(Set(locales.compactMap { $0.language.languageCode?.identifier })).sorted()
    }

    func installedLocaleCodes() async -> [String] {
        let locales = await SpeechTranscriber.installedLocales
        return Array(Set(locales.compactMap { $0.language.languageCode?.identifier })).sorted()
    }

    func maxReservedLocales() async -> Int { await AssetInventory.maximumReservedLocales }

    /// The user's macOS preferred languages that Apple Speech supports — the default check set.
    func systemPreferredCodes() async -> [String] {
        let supported = Set(await availableLocaleCodes())
        return Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .filter { supported.contains($0) }
    }

    func install(localeCode: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeCode)) else {
            throw LocalTranscriptionError.transcriptionFailed("Language \"\(localeCode)\" isn't available for Apple Speech.")
        }
        if await AssetInventory.reservedLocales.count >= AssetInventory.maximumReservedLocales,
           !(await AssetInventory.reservedLocales.contains { $0.identifier == locale.identifier }) {
            throw LocalTranscriptionError.transcriptionFailed(
                "Apple Speech allows at most \(await AssetInventory.maximumReservedLocales) reserved languages. Remove one first.")
        }
        progress(0)
        try await ensureInstalled(locale)
        progress(1)
    }

    func release(localeCode: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeCode)) else { return }
        try await AssetInventory.release(reservedLocale: locale)
    }
```

- [ ] **Step 2: Add per-locale state + actions to the store**

`LocalModelsStore` talks to the service, not the engine directly. Add narrow pass-throughs on `LocalTranscriptionService` first (`AppleSpeechEngine` is behind the `appleSpeech` optional):

In `LocalTranscriptionService.swift`:

```swift
    // Apple Speech per-locale management (no-ops when the engine is absent / not macOS 26).
    public func appleSpeechAvailableLocales() async -> [String] {
        if #available(macOS 26, *), let e = appleSpeech as? AppleSpeechEngine { return await e.availableLocaleCodes() }
        return []
    }
    public func appleSpeechInstalledLocales() async -> [String] {
        if #available(macOS 26, *), let e = appleSpeech as? AppleSpeechEngine { return await e.installedLocaleCodes() }
        return []
    }
    public func appleSpeechSystemPreferred() async -> [String] {
        if #available(macOS 26, *), let e = appleSpeech as? AppleSpeechEngine { return await e.systemPreferredCodes() }
        return []
    }
    public func appleSpeechInstall(localeCode: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if #available(macOS 26, *), let e = appleSpeech as? AppleSpeechEngine {
            try await e.install(localeCode: localeCode, progress: progress)
        }
    }
    public func appleSpeechRelease(localeCode: String) async throws {
        if #available(macOS 26, *), let e = appleSpeech as? AppleSpeechEngine { try await e.release(localeCode: localeCode) }
    }
```

Then in `LocalModelsStore.swift`, add the observable state + actions:

```swift
    public struct AppleSpeechLocaleState: Sendable, Equatable {
        public var available: [String] = []
        public var installed: Set<String> = []
        public var inFlight: Set<String> = []
        public init() {}
    }
    public private(set) var appleLocales = AppleSpeechLocaleState()

    public func refreshAppleLocales() async {
        var s = AppleSpeechLocaleState()
        s.available = await service.appleSpeechAvailableLocales()
        s.installed = Set(await service.appleSpeechInstalledLocales())
        appleLocales = s
    }

    public func toggleAppleLocale(_ code: String, install: Bool) async {
        appleLocales.inFlight.insert(code)
        do {
            if install {
                try await service.appleSpeechInstall(localeCode: code) { _ in }
                appleLocales.installed.insert(code)
            } else {
                try await service.appleSpeechRelease(localeCode: code)
                appleLocales.installed.remove(code)
            }
        } catch { lastError = error.localizedDescription }
        appleLocales.inFlight.remove(code)
    }
```

- [ ] **Step 3: Render the installer in the card**

In `ModelCardView.swift`, add a `store` dependency so the Apple Speech card can drive per-locale actions (thread it from `ModelsView`: add `store: store` to the `ModelCardView(...)` call). Then replace the chip grid for `.appleSpeech` with checkable rows:

```swift
    @ViewBuilder private var languageChips: some View {
        if model.runner == .appleSpeech {
            appleSpeechInstaller
        } else {
            // existing read-only chip grid (unchanged)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(model.supportedLanguages, id: \.self) { code in
                    Text(code).font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private var appleSpeechInstaller: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(store.appleLocales.available, id: \.self) { code in
                let installed = store.appleLocales.installed.contains(code)
                let busy = store.appleLocales.inFlight.contains(code)
                Button {
                    Task { await store.toggleAppleLocale(code, install: !installed) }
                } label: {
                    HStack(spacing: 4) {
                        if busy { ProgressView().controlSize(.mini) }
                        else { Image(systemName: installed ? "checkmark.circle.fill" : "circle") }
                        Text(code).font(.caption2.monospaced())
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(installed ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quinary),
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }
```

For `.appleSpeech`, drive `canExpandLanguages` off the live list and load it on expand:

```swift
    private var canExpandLanguages: Bool {
        model.runner == .appleSpeech ? true : model.supportedLanguages.count > 1
    }
```

Add to the card body, after the `languagesRow`/`languageChips` block, a load-on-first-expand and default pre-check:

```swift
        .task(id: languagesExpanded) {
            guard model.runner == .appleSpeech, languagesExpanded, store.appleLocales.available.isEmpty else { return }
            await store.refreshAppleLocales()
            // Pre-check system-preferred languages that aren't installed yet.
            let preferred = await store.service_appleSpeechSystemPreferred()   // see note
            for code in preferred where !store.appleLocales.installed.contains(code) {
                await store.toggleAppleLocale(code, install: true)
            }
        }
```

> Note: expose `appleSpeechSystemPreferred()` on the store as a thin wrapper over `service.appleSpeechSystemPreferred()` (name it `systemPreferredAppleLocales()`), rather than reaching into `service` from the view. Add:
> ```swift
> public func systemPreferredAppleLocales() async -> [String] { await service.appleSpeechSystemPreferred() }
> ```
> and call `store.systemPreferredAppleLocales()` in the `.task` above.

- [ ] **Step 4: Build the app target**

Run: `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual check (macOS 26 host)**

Local Models → expand the Apple Speech card. Expected: a grid of language codes; the system-preferred ones auto-install (spinner → filled check); clicking an installed one releases it; clicking an uninstalled one installs it. Selecting beyond `maximumReservedLocales` surfaces the cap error in the Logs/error surface.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/LocalModelsStore.swift \
        Amanuensis/UI/Models/ModelCardView.swift \
        Amanuensis/UI/Models/ModelsView.swift
git commit -m "feat(local): per-language installer for Apple Speech model card

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Gated integration test + end-to-end verification

Prove the real engine transcribes on macOS 26, mirroring `IndicConformerIntegrationTests`: skip silently when Apple Speech is unavailable, otherwise transcribe a fixture clip and assert non-empty text + word timings.

**Files:**
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechIntegrationTests.swift` (create)

- [ ] **Step 1: Write the gated integration test**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechIntegrationTests.swift`. Reuse whatever audio fixture the existing local tests use (find it: `rg -l "forResource|Bundle.module|\.flac\"|\.wav\"" Packages/AudioPipeline/Tests/LocalTranscriptionTests`); substitute the real path/loader below.

```swift
import Testing
import Foundation
@testable import LocalTranscription

@available(macOS 26, *)
@Suite struct AppleSpeechIntegrationTests {
    /// Skips (passes) unless Apple Speech is available on this device — CI/sandbox safe.
    private func requireAvailable() async throws {
        guard await SpeechTranscriber.isAvailable else {
            throw XCTSkipLikeSkip("Apple Speech unavailable on this device")
        }
    }

    @Test func transcribesEnglishClip() async throws {
        guard await SpeechTranscriber.isAvailable else { return }   // silent skip
        let engine = AppleSpeechEngine()
        let model = LocalModelCatalog.model(id: "apple-speech")!
        let clip = /* URL of a short English fixture — reuse the existing test fixture */
            URL(fileURLWithPath: "REPLACE_WITH_FIXTURE_PATH")
        let text = try await engine.transcribe(audioURL: clip, model: model, language: "en")
        #expect(!text.isEmpty)
        print("APPLE_SPEECH_E2E[en]: \(text)")

        let words = try await engine.transcribeTimed(audioURL: clip, model: model, language: "en")
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.end >= $0.start })
    }
}
```

> If the suite has no shared skip helper, gate purely with the `guard ... else { return }` shown (no `XCTSkip` dependency needed). Point `clip` at the same fixture the other `LocalTranscriptionTests` use.

- [ ] **Step 2: Run in-sandbox to confirm it skips cleanly**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppleSpeechIntegrationTests`
Expected: PASS quickly (the `isAvailable` guard returns early if assets/permissions aren't present in the SPM process). No failure.

- [ ] **Step 3: Run the real e2e outside the sandbox (macOS 26 host)**

Via the xcode-build daemon or in-app test host, run the suite where `SpeechTranscriber.isAvailable == true`.
Expected: `APPLE_SPEECH_E2E[en]: …` printed with real transcript; timings non-empty.

- [ ] **Step 4: Full manual verification checklist**

Launch the app and confirm:
- Local Models shows Apple Speech; expanding installs system-preferred languages.
- Create a transcription **Job** with model = Apple Speech → runs, produces text.
- A **dictation** capture with Apple Speech selected → produces text (routes through `BatchTranscriber`).
- A recording with 2+ speakers transcribed with diarization ON → speaker-attributed output (proves `transcribeTimed` → diarized path).
- On a macOS < 26 machine (or by temporarily forcing `isAvailableOnThisOS` false): the card is absent and selecting it isn't possible.

- [ ] **Step 5: Final full suite + app build**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS.
Run: `xcodebuild -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Tests/LocalTranscriptionTests/AppleSpeechIntegrationTests.swift
git commit -m "test(local): gated Apple Speech end-to-end integration test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Zero-download / accuracy / timestamps motivations → Tasks 2–3 (engine, timings). ✓
- New engine + runner + catalog row + service wiring + composition root → Task 1 (plumbing), Task 2 (AppCoordinator). ✓
- API mapping table (transcribe/timed/isDownloaded/download/delete/preload/gate) → Tasks 2–3. ✓
- Language resolution (supported passthrough, system→en fallback, no silent wrong-language) → Task 2 `resolveLocale` (throws on explicit-unsupported). ✓
- Install-on-demand self-heal → Task 3 `ensureInstalled` in transcribe/timed. ✓
- Installer UI (show languages, pre-check system-preferred, unselect) → Task 5. ✓
- `maximumReservedLocales` cap surfaced → Task 5 `install`. ✓
- Availability gating (whole-file `@available`, optional service property, gated composition, catalog filter) → Tasks 1, 2, 4. ✓
- "System" size, not "~0 bytes" → Task 4. ✓
- Testing (fake-backed service tests, pure timing unit test, gated integration) → Tasks 1, 3, 6. ✓
- Open questions Q1 (`isDownloaded` per-locale) resolved in Task 2 (resolved-default-locale baseline + self-heal); Q2 (cap) surfaced as an error in Task 5 (LRU-release deferred, documented); Q3 (`requiresNewerOS`) added in Task 1; Q4 (CI SDK) — the `@available` file compiles on the x86 leg because symbols are gated; called out in Global Constraints.

**Placeholder scan:** One intentional `REPLACE_WITH_FIXTURE_PATH` in Task 6 Step 1, with an explicit `rg` command to locate the real fixture — a value only discoverable in the repo, not a hand-wave. No other TBD/TODO.

**Type consistency:** `timedWords(from:)`, `resolveLocale`, `ensureInstalled`, `runAnalyzer`, the `appleSpeech*` service pass-throughs, and `AppleSpeechLocaleState`/`toggleAppleLocale`/`refreshAppleLocales`/`systemPreferredAppleLocales` are named identically across the tasks that define and consume them. `LocalTranscriptionError.requiresNewerOS` / `.timingsUnavailable(plainText:)` match the existing enum.

## Execution Handoff

Two execution options — see below.
