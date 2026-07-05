# Local Speaker Diarization (Phase A + storage groundwork) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Batch local-transcription jobs produce speaker-attributed output (`"Speaker N: …"`) for multi-speaker recordings, on-device, with no new dependency and no user toggle — plus the recording-storage groundwork (per-track FLACs) that the later channel-aware phase needs.

**Architecture:** Two independent groups. **Group 1 (storage)** makes recording-stop emit `mic.flac` + `system.flac` alongside `combined.flac`, gated by a new "keep separate tracks" setting (default on), and flips the `.caf`-retention default to off. **Group 2 (diarization)** runs FluidAudio's `DiarizerManager` on `combined.flac` in parallel with a WhisperKit transcription that now carries word timestamps, aligns words to speaker turns by time, and renders via the existing `formatSpeakerRuns`. Diarization is always-on for the batch job path only (dictation stays plain) via a `diarize` flag on the local sender.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, SPM umbrella package `AudioPipeline`, FluidAudio 0.15.4 (already linked — its `DiarizerManager` + `AudioConverter`), WhisperKit (already linked — `wordTimestamps`), Core ML/ANE.

## Global Constraints

- **No new dependency.** FluidAudio `0.15.4` (already pinned in `Packages/AudioPipeline/Package.swift`) ships the diarizer; do not add packages.
- **Default actor isolation is `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Heavy work runs off-main behind an `actor` or `Task.detached`. `DiarizerManager` is a **non-Sendable, non-actor `final class` whose run method is synchronous/blocking** — it must live entirely inside one dedicated background `actor`; never cross an actor boundary with the instance.
- **arm64-only, runtime-gated.** Local model code is already gated by `LocalModelSupport.isSupported`; the diarizer inherits that gate. Add no new `#if arch` conditionals.
- **SPM tests:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter <Suite>`. **After SPM tests pass, rebuild the app target** (SPM does not compile the app): `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`.
- **Diarizer choice:** `DiarizerManager` (frame-based clustering, arbitrary unknown speaker count via `numClusters: -1`), **not** `OfflineDiarizerManager` or `SortformerDiarizer`.
- **ASR scope:** diarization is honored only for WhisperKit models (the only engine with word timestamps this phase). Other engines fall back to plain transcript.
- **Rendering rule:** ≤1 distinct speaker (or a timestamp-incapable engine) → plain text, no labels. ≥2 → `"Speaker N: …"`.
- **Commits:** Conventional Commits (`feat:`, `refactor:`, `test:`). End commit messages with the `Co-Authored-By` trailer per repo convention.

---

## File Structure

**Group 1 — recording storage**
- Modify `Packages/AudioPipeline/Sources/RecordingStorage/RecordingStore.swift` — add `micFlacURL`/`systemFlacURL` to `RecordingFolder`.
- Modify `Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift` — add `exportTrack(source:to:)`.
- Modify `Packages/AudioPipeline/Sources/RecordingCore/RecordingConversionService.swift` — per-track export + `keepSeparateTracks`.
- Modify `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` — add `keepSeparateTracks`; flip `keepOriginalCAF` default.
- Modify `Amanuensis/UI/SettingsView.swift` — sibling toggle.
- Modify `Amanuensis/AppCoordinator.swift` — thread the new settings/URLs into `startConversion`.

**Group 2 — diarization**
- Modify `Packages/AudioPipeline/Sources/AudioPipelineJobs/SpeakerTranscript.swift` — make `formatSpeakerRuns` `public`.
- Create `Packages/AudioPipeline/Sources/LocalTranscription/TimedWord.swift` — `TimedWord`, `DiarizedSegment` DTOs.
- Create `Packages/AudioPipeline/Sources/LocalTranscription/SpeakerAlignment.swift` — pure align-by-time function.
- Create `Packages/AudioPipeline/Sources/LocalTranscription/SpeakerDiarizer.swift` — `SpeakerDiarizing` protocol + `FluidAudioDiarizer` actor.
- Modify `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift` — add `transcribeTimed` (default throws) + `.timestampsUnsupported`.
- Modify `Packages/AudioPipeline/Sources/LocalTranscription/WhisperKitEngine.swift` — implement `transcribeTimed`.
- Modify `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift` — inject diarizer; add `transcribeDiarized`.
- Modify `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionSender.swift` — `diarize` flag.
- Modify `Amanuensis/AppCoordinator.swift` — register a diarizing batch handler for `JobRunner`.

**Tests**
- `Packages/AudioPipeline/Tests/RecordingStorageTests/` — `RecordingFolder` URLs.
- `Packages/AudioPipeline/Tests/RecordingCoreTests/` — `exportTrack`, conversion retention.
- `Packages/AudioPipeline/Tests/AppSettingsTests/` — new defaults.
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/` — `formatSpeakerRuns` public.
- `Packages/AudioPipeline/Tests/LocalTranscriptionTests/` — alignment, service orchestration, gated E2E.

---

## GROUP 1 — Recording storage groundwork

### Task 1: Per-track FLAC URLs + single-track exporter

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingStorage/RecordingStore.swift:56-59`
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift:20`
- Test: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingFolderTests.swift` (new or existing suite)
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/CombinedFLACExporterTests.swift` (new or existing suite)

**Interfaces:**
- Produces: `RecordingFolder.micFlacURL: URL`, `RecordingFolder.systemFlacURL: URL`; `CombinedFLACExporter.exportTrack(source: URL, to destination: URL) async throws`.

- [ ] **Step 1: Write the failing test for the folder URLs**

Add to `RecordingStorageTests` (Swift Testing):

```swift
import Testing
import Foundation
@testable import RecordingStorage

@Test func recordingFolderExposesPerTrackFlacURLs() {
    let base = URL(filePath: "/tmp/rec")
    let folder = RecordingFolder(url: base, name: "rec", startedAt: Date(timeIntervalSince1970: 0))
    #expect(folder.micFlacURL.lastPathComponent == "mic.flac")
    #expect(folder.systemFlacURL.lastPathComponent == "system.flac")
}
```

- [ ] **Step 2: Run it — expect FAIL** (`value of type 'RecordingFolder' has no member 'micFlacURL'`)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter recordingFolderExposesPerTrackFlacURLs`

- [ ] **Step 3: Add the URLs** after `combinedURL` (line 58):

```swift
    public var micFlacURL: URL { url.appending(path: "mic.flac", directoryHint: .notDirectory) }
    public var systemFlacURL: URL { url.appending(path: "system.flac", directoryHint: .notDirectory) }
```

- [ ] **Step 4: Run it — expect PASS**

- [ ] **Step 5: Write the failing test for `exportTrack`**

Add to `RecordingCoreTests`:

```swift
import Testing
import Foundation
import AVFoundation
@testable import RecordingCore

@Test func exportTrackWrites16kMonoFlac() async throws {
    // Synthesize a 0.5s 44.1kHz mono source .caf.
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let src = dir.appending(path: "src.caf")
    let dst = dir.appending(path: "src.flac")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try AVAudioFile(forWriting: src, settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 22_050)!
    buf.frameLength = 22_050
    for i in 0..<22_050 { buf.floatChannelData![0][i] = 0.1 * Float(sin(Double(i) * 0.1)) }
    try file.write(from: buf)

    try await CombinedFLACExporter.exportTrack(source: src, to: dst)

    let out = try AVAudioFile(forReading: dst)
    #expect(out.fileFormat.sampleRate == 16_000)
    #expect(out.fileFormat.channelCount == 1)
    #expect(out.length > 0)
    try? FileManager.default.removeItem(at: dir)
}
```

- [ ] **Step 6: Run it — expect FAIL** (`type 'CombinedFLACExporter' has no member 'exportTrack'`)

- [ ] **Step 7: Add `exportTrack`** inside the `CombinedFLACExporter` enum (after `combine`, ~line 46). It reuses the existing private helpers:

```swift
    /// Encode a single source track to its own 16 kHz mono FLAC (no summing).
    public nonisolated static func exportTrack(source: URL, to destination: URL) async throws {
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw ExportError.mixFormatUnavailable }
        let buffer = try Self.readAndConvert(url: source, to: mixFormat)
        try Self.writeFLAC(buffer: buffer, to: destination)
    }
```

- [ ] **Step 8: Run both tests — expect PASS**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter "recordingFolderExposesPerTrackFlacURLs|exportTrackWrites16kMonoFlac"`

- [ ] **Step 9: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingStorage/RecordingStore.swift \
        Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift \
        Packages/AudioPipeline/Tests/RecordingStorageTests Packages/AudioPipeline/Tests/RecordingCoreTests
git commit -m "feat(recording): per-track FLAC URLs + single-track exporter"
```

---

### Task 2: Settings — `keepSeparateTracks` (default on) + flip `keepOriginalCAF` default

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift:33-35,77-81,109-116`
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/`

**Interfaces:**
- Produces: `AppSettings.keepSeparateTracks: Bool` (default `true`); `AppSettings.keepOriginalCAF` default now `false`.

- [ ] **Step 1: Write the failing test** (use a fresh `UserDefaults` suite so no stored value exists):

```swift
import Testing
import Foundation
@testable import AppSettings

@Test func retentionDefaults() {
    let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    #expect(settings.keepSeparateTracks == true)
    #expect(settings.keepOriginalCAF == false)
}
```

> If `AppSettings.init` doesn't already accept a `defaults:` parameter, use the existing initializer the other `AppSettingsTests` use — mirror their setup exactly rather than inventing one.

- [ ] **Step 2: Run it — expect FAIL** (`no member 'keepSeparateTracks'` and/or `keepOriginalCAF == false` fails)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter retentionDefaults`

- [ ] **Step 3: Implement.** (a) Add the property next to `keepOriginalCAF` (~line 35):

```swift
    // When true, per-track mic.flac / system.flac are kept alongside combined.flac
    // (needed for channel-aware diarization). Default true.
    public var keepSeparateTracks: Bool {
        didSet { defaults.set(keepSeparateTracks, forKey: Keys.keepSeparateTracks) }
    }
```

(b) Add the key to the `Keys` enum (~line 112):

```swift
        static let keepSeparateTracks = "keepSeparateTracks"
```

(c) In `init`, initialize it (mirror the `keepOriginalCAF` block at 77-81) **and flip the `keepOriginalCAF` else-branch from `true` to `false`**:

```swift
        if defaults.object(forKey: Keys.keepOriginalCAF) != nil {
            keepOriginalCAF = defaults.bool(forKey: Keys.keepOriginalCAF)
        } else {
            keepOriginalCAF = false
        }
        if defaults.object(forKey: Keys.keepSeparateTracks) != nil {
            keepSeparateTracks = defaults.bool(forKey: Keys.keepSeparateTracks)
        } else {
            keepSeparateTracks = true
        }
```

(d) Update the `keepOriginalCAF` doc comment (lines 28-32) to note the default is now `false`.

- [ ] **Step 4: Run it — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift Packages/AudioPipeline/Tests/AppSettingsTests
git commit -m "feat(settings): keepSeparateTracks default on; keepOriginalCAF default off"
```

---

### Task 3: Conversion service emits per-track FLACs, honoring `keepSeparateTracks`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/RecordingConversionService.swift:25-78`
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/`

**Interfaces:**
- Consumes: `CombinedFLACExporter.exportTrack` (Task 1) as the default `ExportTrack` closure.
- Produces: `startConversion(folderName:mic:system:destination:micFlac:systemFlac:keepSourcesOnSuccess:keepSeparateTracks:)`.

- [ ] **Step 1: Write the failing test** (inject fakes — no real audio; each closure just touches its destination file):

```swift
import Testing
import Foundation
@testable import RecordingCore

@Test func conversionKeepsSeparateTracksWhenEnabled() async throws {
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mic = dir.appending(path: "mic.caf");     FileManager.default.createFile(atPath: mic.path, contents: Data())
    let sys = dir.appending(path: "system.caf");  FileManager.default.createFile(atPath: sys.path, contents: Data())
    let combined = dir.appending(path: "combined.flac")
    let micFlac = dir.appending(path: "mic.flac")
    let sysFlac = dir.appending(path: "system.flac")

    let svc = RecordingConversionService(
        combine: { _, _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) },
        exportTrack: { _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) })

    let outcome = await svc.startConversion(
        folderName: "f", mic: mic, system: sys, destination: combined,
        micFlac: micFlac, systemFlac: sysFlac,
        keepSourcesOnSuccess: false, keepSeparateTracks: true).value

    #expect({ if case .success = outcome.result { return true } else { return false } }())
    #expect(FileManager.default.fileExists(atPath: micFlac.path))   // separate FLAC kept
    #expect(FileManager.default.fileExists(atPath: sysFlac.path))
    #expect(!FileManager.default.fileExists(atPath: mic.path))      // .caf deleted (keepSources false)
    try? FileManager.default.removeItem(at: dir)
}

@Test func conversionSkipsSeparateTracksWhenDisabled() async throws {
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mic = dir.appending(path: "mic.caf");     FileManager.default.createFile(atPath: mic.path, contents: Data())
    let combined = dir.appending(path: "combined.flac")
    let micFlac = dir.appending(path: "mic.flac")

    let svc = RecordingConversionService(
        combine: { _, _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) },
        exportTrack: { _, dest in FileManager.default.createFile(atPath: dest.path, contents: Data()) })

    _ = await svc.startConversion(
        folderName: "f", mic: mic, system: nil, destination: combined,
        micFlac: micFlac, systemFlac: nil,
        keepSourcesOnSuccess: true, keepSeparateTracks: false).value

    #expect(!FileManager.default.fileExists(atPath: micFlac.path)) // not produced when disabled
    #expect(FileManager.default.fileExists(atPath: mic.path))      // .caf kept
    try? FileManager.default.removeItem(at: dir)
}
```

- [ ] **Step 2: Run — expect FAIL** (`init` has no `exportTrack:`; `startConversion` has no `micFlac:` etc.)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter "conversionKeepsSeparateTracksWhenEnabled|conversionSkipsSeparateTracksWhenDisabled"`

- [ ] **Step 3: Implement.** (a) Add the `ExportTrack` typealias + stored closure + init param (near the existing `Combine` block, lines 25-36):

```swift
    public typealias ExportTrack = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    private let combine: Combine
    private let exportTrack: ExportTrack
    private var inflight: [String: Task<Outcome, Never>] = [:]

    public init(
        combine: @escaping Combine = { mic, system, destination in
            try await CombinedFLACExporter.combine(mic: mic, system: system, to: destination)
        },
        exportTrack: @escaping ExportTrack = { source, destination in
            try await CombinedFLACExporter.exportTrack(source: source, to: destination)
        }
    ) {
        self.combine = combine
        self.exportTrack = exportTrack
    }
```

(b) Extend `startConversion` (lines 38-78). New signature + per-track export **before** the `.caf` deletion:

```swift
    public func startConversion(
        folderName: String,
        mic: URL,
        system: URL?,
        destination: URL,
        micFlac: URL,
        systemFlac: URL?,
        keepSourcesOnSuccess: Bool,
        keepSeparateTracks: Bool
    ) -> Task<Outcome, Never> {
        if let existing = inflight[folderName] { return existing }
        let combine = self.combine
        let exportTrack = self.exportTrack
        let task = Task.detached(priority: .utility) {
            let outcome: Outcome
            do {
                try await combine(mic, system, destination)
                if keepSeparateTracks {
                    do { try await exportTrack(mic, micFlac) }
                    catch { Self.log.error("failed to export mic FLAC: \(String(describing: error), privacy: .public)") }
                    if let system, let systemFlac {
                        do { try await exportTrack(system, systemFlac) }
                        catch { Self.log.error("failed to export system FLAC: \(String(describing: error), privacy: .public)") }
                    }
                }
                if !keepSourcesOnSuccess {
                    do { try FileManager.default.removeItem(at: mic) }
                    catch { Self.log.error("failed to remove mic CAF after conversion: \(String(describing: error), privacy: .public)") }
                    if let system {
                        do { try FileManager.default.removeItem(at: system) }
                        catch { Self.log.error("failed to remove system CAF after conversion: \(String(describing: error), privacy: .public)") }
                    }
                }
                outcome = Outcome(folderName: folderName, result: .success(()))
            } catch {
                Self.log.error("conversion failed for \(folderName, privacy: .public): \(String(describing: error), privacy: .public)")
                outcome = Outcome(folderName: folderName, result: .failure(ConversionFailure(message: error.localizedDescription)))
            }
            await self.clear(folderName: folderName)
            return outcome
        }
        inflight[folderName] = task
        return task
    }
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/RecordingConversionService.swift Packages/AudioPipeline/Tests/RecordingCoreTests
git commit -m "feat(recording): emit per-track FLACs honoring keepSeparateTracks"
```

---

### Task 4: Wire the setting into the UI and the recording-stop call site (app target)

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift:52-61`
- Modify: `Amanuensis/AppCoordinator.swift:301-314`

**Interfaces:**
- Consumes: `AppSettings.keepSeparateTracks` (Task 2); `RecordingFolder.micFlacURL`/`systemFlacURL` (Task 1); the new `startConversion` signature (Task 3).

> No SPM test — app-target UI/wiring. Verified by the app build in Step 4.

- [ ] **Step 1: Add the toggle** inside the existing `Section("After recording stops")` (after the `keepOriginalCAF` toggle, before the section's closing brace at line 60):

```swift
                Toggle(isOn: $settings.keepSeparateTracks) {
                    VStack(alignment: .leading) {
                        Text("Keep separate mic & system tracks")
                        Text("Also save mic.flac and system.flac next to the combined recording. Needed for per-speaker attribution of group recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 2: Update the `startConversion` call** (lines 308-314) to pass the new arguments (the surrounding `keepCAF`/`micURL`/`systemURL`/`combinedURL`/`folder` locals at 301-305 already exist):

```swift
        let conversionTask = await conversionService.startConversion(
            folderName: folderName,
            mic: micURL,
            system: systemURL,
            destination: combinedURL,
            micFlac: folder.micFlacURL,
            systemFlac: systemURL == nil ? nil : folder.systemFlacURL,
            keepSourcesOnSuccess: keepCAF,
            keepSeparateTracks: settings.keepSeparateTracks
        )
```

- [ ] **Step 3: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: **BUILD SUCCEEDED**

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/SettingsView.swift Amanuensis/AppCoordinator.swift
git commit -m "feat(settings): keep-separate-tracks toggle + wire into recording stop"
```

---

## GROUP 2 — Diarization (Phase A)

### Task 5: DTO types + make `formatSpeakerRuns` public

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/TimedWord.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SpeakerTranscript.swift:7`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/`

**Interfaces:**
- Produces: `public struct TimedWord: Sendable, Equatable { text: String; start: Double; end: Double }`; `public struct DiarizedSegment: Sendable, Equatable { speakerId: String; start: Double; end: Double }`; `public func formatSpeakerRuns<Speaker: Hashable>(_ runs: [(speaker: Speaker, text: String)]) -> String`.

- [ ] **Step 1: Write the failing test** for the now-public formatter (cross-module use):

```swift
import Testing
@testable import AudioPipelineJobs

@Test func formatSpeakerRunsIsPublicAndNumbersInFirstSeenOrder() {
    let out = formatSpeakerRuns([(speaker: "A", text: "hi"), (speaker: "B", text: "yo"), (speaker: "A", text: "again")])
    #expect(out == "Speaker 1: hi\nSpeaker 2: yo\nSpeaker 1: again")
}
```

> This test lives in the same module, so it passes today. Its purpose is to lock the exact output format the diarization path depends on; the `public` change is verified by Task 9's cross-module use. (If `AudioPipelineJobsTests` uses `@testable import`, switch it to a plain `import AudioPipelineJobs` here to prove the symbol is `public` — that import fails to resolve the free function unless it's `public`.)

Use plain import to actually prove `public`:

```swift
import Testing
import AudioPipelineJobs   // NOT @testable — proves formatSpeakerRuns is public

@Test func formatSpeakerRunsIsPublic() {
    #expect(formatSpeakerRuns([(speaker: 1, text: "a"), (speaker: 2, text: "b")]) == "Speaker 1: a\nSpeaker 2: b")
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'formatSpeakerRuns' in scope` via the non-testable import)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter formatSpeakerRunsIsPublic`

- [ ] **Step 3: Implement.** (a) Make the function public — `SpeakerTranscript.swift:7`:

```swift
public func formatSpeakerRuns<Speaker: Hashable>(_ runs: [(speaker: Speaker, text: String)]) -> String {
```

(b) Create `TimedWord.swift`:

```swift
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct DiarizedSegment: Sendable, Equatable {
    public let speakerId: String
    public let start: Double
    public let end: Double
    public init(speakerId: String, start: Double, end: Double) {
        self.speakerId = speakerId; self.start = start; self.end = end
    }
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SpeakerTranscript.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/TimedWord.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests
git commit -m "feat(local): TimedWord/DiarizedSegment DTOs; make formatSpeakerRuns public"
```

---

### Task 6: Speaker alignment (pure function) — highest-value unit tests

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/SpeakerAlignment.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/SpeakerAlignmentTests.swift`

**Interfaces:**
- Consumes: `TimedWord`, `DiarizedSegment` (Task 5).
- Produces: `func attributeSpeakers(words: [TimedWord], segments: [DiarizedSegment]) -> [(speaker: String, text: String)]` (module-internal).

The rule: assign each word to the speaker of the segment containing the word's **midpoint**; if the midpoint is in no segment, use the **nearest** segment (by distance to `[start,end]`). Merge consecutive same-speaker words into one run; concatenate their raw `text` (WhisperKit words carry their own leading spaces) and trim each run.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import LocalTranscription

private func w(_ t: String, _ s: Double, _ e: Double) -> TimedWord { TimedWord(text: t, start: s, end: e) }
private func seg(_ id: String, _ s: Double, _ e: Double) -> DiarizedSegment { DiarizedSegment(speakerId: id, start: s, end: e) }

@Test func groupsConsecutiveWordsBySpeaker() {
    let words = [w(" Hello", 0.0, 0.5), w(" there", 0.5, 1.0), w(" hi", 2.0, 2.5)]
    let segs  = [seg("S1", 0.0, 1.5), seg("S2", 1.5, 3.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.count == 2)
    #expect(runs[0].speaker == "S1")
    #expect(runs[0].text == "Hello there")
    #expect(runs[1].speaker == "S2")
    #expect(runs[1].text == "hi")
}

@Test func wordInGapUsesNearestSegment() {
    let words = [w(" x", 5.0, 5.2)]                 // midpoint 5.1, inside no segment
    let segs  = [seg("S1", 0.0, 1.0), seg("S2", 6.0, 7.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.count == 1)
    #expect(runs[0].speaker == "S2")               // nearest is S2 (0.9 away vs 4.1)
}

@Test func singleSpeakerProducesOneRun() {
    let words = [w(" a", 0.0, 0.5), w(" b", 0.5, 1.0)]
    let segs  = [seg("S1", 0.0, 2.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.count == 1)
    #expect(runs[0].text == "a b")
}

@Test func emptySegmentsYieldEmpty() {
    #expect(attributeSpeakers(words: [w(" a", 0, 1)], segments: []).isEmpty)
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'attributeSpeakers' in scope`)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SpeakerAlignmentTests`

- [ ] **Step 3: Implement `SpeakerAlignment.swift`:**

```swift
import Foundation

/// Assign each transcribed word to a diarized speaker by time, then merge
/// consecutive same-speaker words into runs. WhisperKit words carry their own
/// leading spaces, so run text is a plain concatenation, trimmed per run.
func attributeSpeakers(words: [TimedWord], segments: [DiarizedSegment]) -> [(speaker: String, text: String)] {
    guard !segments.isEmpty else { return [] }
    var runs: [(speaker: String, text: String)] = []
    for word in words {
        let mid = (word.start + word.end) / 2
        let speaker = speakerId(forMidpoint: mid, in: segments)
        if let last = runs.last, last.speaker == speaker {
            runs[runs.count - 1].text += word.text
        } else {
            runs.append((speaker: speaker, text: word.text))
        }
    }
    return runs.map { (speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespaces)) }
}

private func speakerId(forMidpoint mid: Double, in segments: [DiarizedSegment]) -> String {
    if let hit = segments.first(where: { mid >= $0.start && mid <= $0.end }) { return hit.speakerId }
    // Nearest by distance to the [start, end] interval.
    let nearest = segments.min { a, b in distance(mid, a) < distance(mid, b) }
    return nearest?.speakerId ?? ""
}

private func distance(_ t: Double, _ s: DiarizedSegment) -> Double {
    if t < s.start { return s.start - t }
    if t > s.end { return t - s.end }
    return 0
}
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/SpeakerAlignment.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/SpeakerAlignmentTests.swift
git commit -m "feat(local): speaker alignment by word-midpoint with nearest-segment fallback"
```

---

### Task 7: Engine timestamped path — protocol default + WhisperKit impl

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift:8-30`
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/WhisperKitEngine.swift:99-118`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/TranscribeTimedDefaultTests.swift`

**Interfaces:**
- Consumes: `TimedWord` (Task 5).
- Produces: `LocalTranscriptionEngine.transcribeTimed(audioURL:model:language:) async throws -> [TimedWord]` (default throws `.timestampsUnsupported`); `LocalTranscriptionError.timestampsUnsupported`.

- [ ] **Step 1: Write the failing test** — a stub engine using the protocol default must throw `.timestampsUnsupported`:

```swift
import Testing
import Foundation
@testable import LocalTranscription

private struct NoTimestampEngine: LocalTranscriptionEngine {
    func isDownloaded(_ model: LocalModel) async -> Bool { true }
    func installedBytes(_ model: LocalModel) async -> Int64 { 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func delete(_ model: LocalModel) async throws {}
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String { "plain" }
    // uses default transcribeTimed
}

@Test func defaultTranscribeTimedThrowsUnsupported() async {
    let engine = NoTimestampEngine()
    let model = LocalModelCatalog.all[0]
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await engine.transcribeTimed(audioURL: URL(filePath: "/dev/null"), model: model, language: nil)
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`value of type ... has no member 'transcribeTimed'`)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter defaultTranscribeTimedThrowsUnsupported`

- [ ] **Step 3: Implement.** (a) `LocalTranscriptionEngine.swift` — add the requirement to the protocol (after line 8) and a throwing default (in the `extension`, after line 15); add the error case:

```swift
    // protocol body, after transcribe(...):
    func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord]
```

```swift
public extension LocalTranscriptionEngine {
    func preload(_ model: LocalModel) async throws {}
    func unloadResident() async {}
    func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] {
        throw LocalTranscriptionError.timestampsUnsupported(model.displayName)
    }
}
```

Add to `LocalTranscriptionError` (after `case transcriptionFailed(String)`):

```swift
    case timestampsUnsupported(String)
```

And an `errorDescription` arm:

```swift
        case .timestampsUnsupported(let m): return "Word timestamps are not supported by \(m)."
```

(b) `WhisperKitEngine.swift` — add `transcribeTimed` after `transcribe` (line 118). It mirrors `transcribe` but sets `wordTimestamps: true` and maps the words:

```swift
    public func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] {
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        let pipe: WhisperKit
        if model.id == residentModelID, let cached = resident {
            pipe = cached
        } else {
            pipe = try await buildPipeline(model)
        }
        let opts = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            wordTimestamps: true,
            chunkingStrategy: .vad)
        let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: opts)
        return results.flatMap { $0.allWords }.map {
            TimedWord(text: $0.word, start: Double($0.start), end: Double($0.end))
        }
    }
```

> Confirm the `DecodingOptions` initializer accepts `language:`, `detectLanguage:`, `wordTimestamps:`, `chunkingStrategy:` together — it does per `Configurations.swift`; keep the argument order the initializer declares.

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/WhisperKitEngine.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/TranscribeTimedDefaultTests.swift
git commit -m "feat(local): transcribeTimed engine path (WhisperKit word timestamps)"
```

---

### Task 8: FluidAudio diarizer wrapper (actor) behind a `SpeakerDiarizing` protocol

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/SpeakerDiarizer.swift`
- Test: none new here (unit coverage comes via the fake in Task 9; the real actor is exercised by the gated E2E in Task 10).

**Interfaces:**
- Consumes: `DiarizedSegment` (Task 5); FluidAudio `DiarizerManager`, `DiarizerModels`, `DiarizerConfig`, `TimedSpeakerSegment`.
- Produces: `protocol SpeakerDiarizing: Sendable { func diarize(samples: [Float]) async throws -> [DiarizedSegment] }`; `actor FluidAudioDiarizer: SpeakerDiarizing`.

- [ ] **Step 1: Implement `SpeakerDiarizer.swift`** (no separate failing test — it's a thin adapter over a non-Sendable, model-backed class; behavior is covered by Task 9's fake and Task 10's gated run):

```swift
import Foundation
import FluidAudio

public protocol SpeakerDiarizing: Sendable {
    /// Diarize 16 kHz mono PCM samples into time-stamped anonymous speaker segments.
    func diarize(samples: [Float]) async throws -> [DiarizedSegment]
}

/// Owns the non-Sendable `DiarizerManager` entirely within one actor. Lazily
/// downloads + loads the Core ML models (pyannote segmentation + wespeaker) on
/// first use. `performCompleteDiarization` is synchronous/CPU-blocking; running it
/// inside this dedicated actor keeps it off the main actor.
public actor FluidAudioDiarizer: SpeakerDiarizing {
    private var manager: DiarizerManager?

    public init() {}

    private func ensureLoaded() async throws -> DiarizerManager {
        if let manager { return manager }
        let models = try await DiarizerModels.downloadIfNeeded()
        let m = DiarizerManager(config: .default)   // numClusters: -1 → automatic speaker count
        m.initialize(models: models)
        manager = m
        return m
    }

    public func diarize(samples: [Float]) async throws -> [DiarizedSegment] {
        let m = try await ensureLoaded()
        let result = try m.performCompleteDiarization(samples, sampleRate: 16_000)
        return result.segments
            .filter { !$0.speakerId.isEmpty }
            .map { DiarizedSegment(speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}
```

- [ ] **Step 2: Build the package to confirm it compiles against FluidAudio**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: build succeeds (compiles the new file against FluidAudio's real symbols).

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/SpeakerDiarizer.swift
git commit -m "feat(local): FluidAudio diarizer actor behind SpeakerDiarizing"
```

---

### Task 9: Service orchestration — `transcribeDiarized`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift:1-57`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/TranscribeDiarizedTests.swift`

**Interfaces:**
- Consumes: `attributeSpeakers` (Task 6), `TimedWord`/`DiarizedSegment` (Task 5), `SpeakerDiarizing` (Task 8), `transcribeTimed` (Task 7), `formatSpeakerRuns` (Task 5), FluidAudio `AudioConverter().resampleAudioFile(_:)`.
- Produces: `LocalTranscriptionService.transcribeDiarized(audioURL:modelID:language:) async throws -> String`; new init param `diarizer: any SpeakerDiarizing`.

- [ ] **Step 1: Write the failing tests** (inject a fake WhisperKit engine + fake diarizer; use the real catalog id `"whisper-large-v3-turbo"` so `resolve` routes to the injected `whisperKit`):

```swift
import Testing
import Foundation
@testable import LocalTranscription

private struct FakeTimedEngine: LocalTranscriptionEngine {
    let words: [TimedWord]
    func isDownloaded(_ model: LocalModel) async -> Bool { true }
    func installedBytes(_ model: LocalModel) async -> Int64 { 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func delete(_ model: LocalModel) async throws {}
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
    func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] { words }
}

private struct FakeDiarizer: SpeakerDiarizing {
    let segments: [DiarizedSegment]
    func diarize(samples: [Float]) async throws -> [DiarizedSegment] { segments }
}

// A resampler seam is needed because the real AudioConverter reads a file.
// If LocalTranscriptionService loads samples via an injected closure (see Step 3),
// tests pass a stub. Otherwise these tests must point audioURL at a real 16k mono file.

private let turboID = "whisper-large-v3-turbo"

@Test func diarizedOutputLabelsMultipleSpeakers() async throws {
    let words = [TimedWord(text: " hi", start: 0, end: 0.5), TimedWord(text: " yo", start: 2, end: 2.5)]
    let segs  = [DiarizedSegment(speakerId: "S1", start: 0, end: 1), DiarizedSegment(speakerId: "S2", start: 1.5, end: 3)]
    let service = LocalTranscriptionService(
        fluidAudio: FakeTimedEngine(words: []),
        whisperKit: FakeTimedEngine(words: words),
        indicConformer: FakeTimedEngine(words: []),
        diarizer: FakeDiarizer(segments: segs),
        loadSamples: { _ in [] })
    let out = try await service.transcribeDiarized(audioURL: URL(filePath: "/dev/null"), modelID: turboID, language: "en")
    #expect(out == "Speaker 1: hi\nSpeaker 2: yo")
}

@Test func diarizedOutputIsPlainForSingleSpeaker() async throws {
    let words = [TimedWord(text: " a", start: 0, end: 0.5), TimedWord(text: " b", start: 0.5, end: 1)]
    let segs  = [DiarizedSegment(speakerId: "S1", start: 0, end: 2)]
    let service = LocalTranscriptionService(
        fluidAudio: FakeTimedEngine(words: []),
        whisperKit: FakeTimedEngine(words: words),
        indicConformer: FakeTimedEngine(words: []),
        diarizer: FakeDiarizer(segments: segs),
        loadSamples: { _ in [] })
    let out = try await service.transcribeDiarized(audioURL: URL(filePath: "/dev/null"), modelID: turboID, language: "en")
    #expect(out == "a b")
}
```

> Note the tests rely on an injectable `loadSamples:` closure so no real audio file is read. Implement that seam in Step 3.

- [ ] **Step 2: Run — expect FAIL** (`extra argument 'diarizer'` / `no member 'transcribeDiarized'`)

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TranscribeDiarizedTests`

- [ ] **Step 3: Implement.** Add the injected dependencies to the `init` and the new method. Keep existing engines/logic intact.

Add stored properties + init params (alongside the existing engine fields):

```swift
    private let diarizer: any SpeakerDiarizing
    private let loadSamples: @Sendable (URL) throws -> [Float]

    public init(
        fluidAudio: any LocalTranscriptionEngine,
        whisperKit: any LocalTranscriptionEngine,
        indicConformer: any LocalTranscriptionEngine,
        diarizer: any SpeakerDiarizing = FluidAudioDiarizer(),
        loadSamples: @escaping @Sendable (URL) throws -> [Float] = { try AudioConverter().resampleAudioFile($0) }
    ) {
        // ...assign existing engine fields exactly as before...
        self.diarizer = diarizer
        self.loadSamples = loadSamples
    }
```

Add `import FluidAudio` at the top (for `AudioConverter`) and `import AudioPipelineJobs` (for `formatSpeakerRuns`) if not already imported.

Add the method after `transcribe` (line 57):

```swift
    public func transcribeDiarized(audioURL: URL, modelID: String, language: String?) async throws -> String {
        let (m, e) = try resolve(modelID)
        let words: [TimedWord]
        do {
            words = try await e.transcribeTimed(audioURL: audioURL, model: m, language: language)
        } catch let error as LocalTranscriptionError {
            // Engine can't produce word timestamps → plain transcript, no labels.
            if case .timestampsUnsupported = error {
                return try await e.transcribe(audioURL: audioURL, model: m, language: language)
            }
            throw error
        }
        let plain = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        let segments: [DiarizedSegment]
        do {
            let samples = try loadSamples(audioURL)
            segments = try await diarizer.diarize(samples: samples)
        } catch {
            return plain   // diarization failure degrades to plain transcript
        }
        let runs = attributeSpeakers(words: words, segments: segments)
        let distinct = Set(runs.map(\.speaker))
        if distinct.count <= 1 { return plain }
        return formatSpeakerRuns(runs)
    }
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/TranscribeDiarizedTests.swift
git commit -m "feat(local): transcribeDiarized orchestration with plain/single-speaker fallback"
```

---

### Task 10: Sender flag + batch-only wiring + gated end-to-end test

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionSender.swift:4-22`
- Modify: `Amanuensis/AppCoordinator.swift:107-109,418`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/DiarizationE2ETests.swift` (gated, silently skips without models)

**Interfaces:**
- Consumes: `LocalTranscriptionService.transcribeDiarized` (Task 9).
- Produces: `LocalTranscriptionSender(service:diarize:)`.

- [ ] **Step 1: Add the `diarize` flag to the sender.** `LocalTranscriptionSender.swift`:

```swift
public struct LocalTranscriptionSender: AudioJobSending {
    private let service: LocalTranscriptionService
    private let diarize: Bool

    public init(service: LocalTranscriptionService, diarize: Bool = false) {
        self.service = service
        self.diarize = diarize
    }

    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        guard LocalModelCatalog.model(id: job.model) != nil else {
            throw LocalTranscriptionError.unsupportedModel(job.model)
        }
        let language = LocalModelCatalog.resolvedLanguage(forModel: job.model, requested: job.fields["language"])
        if diarize {
            return try await service.transcribeDiarized(audioURL: audioURL, modelID: job.model, language: language)
        }
        return try await service.transcribe(audioURL: audioURL, modelID: job.model, language: language)
    }
}
```

- [ ] **Step 2: Wire batch-only diarization in `AppCoordinator`.** After the existing `localHandlers` block (lines 107-109), build a diarizing set for the batch runner and switch `JobRunner` to it (line 418). `localHandlers` (dictation, line 116) stays non-diarizing:

```swift
        // ...existing localHandlers (dictation, diarize off) at 107-109 unchanged...
        let batchLocalHandlers = JobRunner.defaultHandlers.merging(
            [.localTranscription: LocalTranscriptionSender(service: localService, diarize: true)]) { _, new in new }
        self.batchLocalHandlers = batchLocalHandlers
```

Add the stored property near line 60:

```swift
    let batchLocalHandlers: [JobShape: any AudioJobSending]
```

Change the `JobRunner` construction (line 418) to use it:

```swift
        let runner = JobRunner(keychain: keychain, handlers: batchLocalHandlers)
```

- [ ] **Step 3: Write the gated E2E test** (real models; silently skips when absent, mirroring `IndicConformerIntegrationTests`):

```swift
import Testing
import Foundation
@testable import LocalTranscription

@Test func diarizesTwoSpeakerFixtureWhenModelsPresent() async throws {
    // Provide a 2-speaker 16k mono fixture path via env; skip silently if unset/missing.
    guard let path = ProcessInfo.processInfo.environment["AMANUENSIS_DIARIZATION_FIXTURE"],
          FileManager.default.fileExists(atPath: path) else { return }
    let samples = try AudioConverter().resampleAudioFile(URL(filePath: path))
    let diarizer = FluidAudioDiarizer()
    let segments = try await diarizer.diarize(samples: samples)
    #expect(Set(segments.map(\.speakerId)).count >= 2)
    #expect(segments.allSatisfy { $0.end > $0.start })
}
```

- [ ] **Step 4: Run the SPM suite** (E2E skips without the fixture; all deterministic tests must pass):

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalTranscriptionTests`
Expected: PASS (E2E test is a no-op without `AMANUENSIS_DIARIZATION_FIXTURE`).

- [ ] **Step 5: Rebuild the app target** (proves the `AppCoordinator` wiring compiles):

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: **BUILD SUCCEEDED**

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionSender.swift \
        Amanuensis/AppCoordinator.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/DiarizationE2ETests.swift
git commit -m "feat(local): batch-only diarizing sender + gated E2E test"
```

---

### Task 11: Full-suite verification + manual smoke

**Files:** none (verification only).

- [ ] **Step 1: Run the full SPM suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all suites PASS.

- [ ] **Step 2: Rebuild the app**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Manual smoke (real run).** Record a short two-person clip (or import one), run a **local WhisperKit** transcription job, and confirm the `.txt` output contains `Speaker 1:` / `Speaker 2:` lines. Record a solo clip and confirm its output is plain (no labels). Confirm `mic.flac`/`system.flac` appear in the recording folder with the toggle on, and are absent with it off.

- [ ] **Step 4: Final commit if any fixups were needed** (otherwise skip).

---

## Self-Review notes (author)

- **Spec coverage:** Part 1 (3 FLACs + toggles) → Tasks 1-4. Part 2 Phase A (always-on batch diarization, timestamp engine change, align, render, plain-fallback) → Tasks 5-10. Testing strategy (alignment unit, rendering rule, retention combos, gated E2E, app rebuild) → Tasks 3,5,6,9,10,11. `.caf` default flip → Task 2. Phase C (channel-aware) is intentionally **out of scope** — separate future plan.
- **Type consistency:** `TimedWord{text,start,end}`, `DiarizedSegment{speakerId,start,end}`, `attributeSpeakers(words:segments:)->[(speaker:String,text:String)]`, `transcribeTimed(audioURL:model:language:)->[TimedWord]`, `SpeakerDiarizing.diarize(samples:)->[DiarizedSegment]`, `transcribeDiarized(audioURL:modelID:language:)->String`, `LocalTranscriptionSender(service:diarize:)` — used consistently across tasks.
- **Known verification points for the implementer:** confirm `AppSettings.init` test-construction matches the existing `AppSettingsTests` setup (Task 2 Step 1 note); confirm the `DecodingOptions` argument order (Task 7); confirm `LocalTranscriptionService.init`'s existing engine-field assignment is preserved when adding the two new params (Task 9 Step 3).
