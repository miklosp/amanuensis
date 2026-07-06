# Auto-Dictation (always-on, VAD-gated) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hands-free dictation mode that keeps the mic on, detects speech with a neural VAD, and transcribes+types each utterance into the focused field until the user toggles it off.

**Architecture:** A continuous mic tap emits fixed 16 kHz mono Float frames → FluidAudio's streaming Silero VAD emits speechStart/speechEnd events → a pure segmenter turns those into segment boundaries (adding a max-cut) → each finalized utterance is written to a temp WAV and transcribed through the *existing* local transcription path (`BatchTranscriber` → `LocalTranscriptionService`), then appended via the existing `TextInserter`. It is toggled by a short tap of the existing dictation trigger when a new `shortTapAction` setting is set to `autoListening`; hold/PTT is unchanged.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, AVFoundation (AVAudioEngine + AVAudioConverter), FluidAudio `VadManager` (already a dependency), CoreML/ANE, Swift Testing (SPM) + XCTest (app-hosted).

## Global Constraints

- **Deployment target macOS 14.4, Swift 6.2.** Bundle id `work.miklos.amanuensis`; product/app name `Amanuensis`; SPM modules keep `AudioPipeline*` names.
- **Default actor isolation is `MainActor`** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Audio-thread closures must be explicitly `nonisolated`/`@Sendable` or they SIGTRAP on the audio thread. Strict concurrency diagnostics are on.
- **Local-only / Apple Silicon.** Auto mode requires a local model and `LocalModelSupport.isSupported == true`. Never runs on Intel or with a remote provider.
- **Append-only into foreign fields.** Utterances are committed whole, on endpoint; no in-field revision. Any live partials stay in the app's own overlay.
- **Engine-agnostic.** Per-utterance transcription MUST route through `BatchTranscriber` (local shape) → `LocalTranscriptionService`, which dispatches to WhisperKit / FluidAudio (Parakeet) / IndicConformer by model. No engine-specific code in the auto loop.
- **VAD I/O contract (FluidAudio 0.15.4):** `VadManager.processStreamingChunk(_:state:config:)` expects **4096-sample (256 ms) 16 kHz mono Float32** chunks; returns `VadStreamResult` whose `.event?.kind` is `.speechStart` / `.speechEnd`. The streaming path enforces `minSilenceDuration` (endpoint pause) but **not** `minSpeechDuration` or `maxSpeechDuration`.
- **Build/test commands (sandbox):**
  - SPM tests: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter <Suite>`
  - App build: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
  - App-hosted tests: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' test`
- **After SPM tests pass, always rebuild the app target** to confirm it still compiles (SPM green ≠ app compiles).

---

## File Structure

**Create**
- `Packages/AudioPipeline/Sources/DictationCore/AutoDictationSegmenter.swift` — pure segment state machine (idle/capturing + max-cut).
- `Packages/AudioPipeline/Sources/RecordingCore/FrameSlicer.swift` — pure: buffer Float samples, emit fixed-size frames.
- `Packages/AudioPipeline/Sources/RecordingCore/SegmentAudioWriter.swift` — write `[Float]` to a 16 kHz mono WAV.
- `Packages/AudioPipeline/Sources/RecordingCore/ContinuousMicTap.swift` — always-on tap → 16 kHz mono Float frames.
- `Packages/AudioPipeline/Sources/LocalTranscription/StreamingVoiceDetector.swift` — actor wrapping FluidAudio `VadManager` streaming; public event enum.
- `Amanuensis/Dictation/AutoDictationController.swift` — owns tap+VAD+segmenter+transcription; `toggle()/stop()/isRunning`.
- `Packages/AudioPipeline/Tests/DictationCoreTests/AutoDictationSegmenterTests.swift`
- `Packages/AudioPipeline/Tests/RecordingCoreTests/FrameSlicerTests.swift`
- `Packages/AudioPipeline/Tests/RecordingCoreTests/SegmentAudioWriterTests.swift`

**Modify**
- `Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift` — add `ShortTapAction` + `shortTapAction`.
- `Amanuensis/Dictation/DictationCoordinator.swift` — route `.toggle` on `shortTapAction`; suppress holds while auto running; stop auto on disable/settings change; accept injected controller.
- `Amanuensis/AppCoordinator.swift` — construct `AutoDictationController`, inject into `DictationCoordinator`.
- `Amanuensis/UI/Dictation/DictationView.swift` — add the short-tap action Picker.
- `Packages/AudioPipeline/Tests/AppSettingsTests/DictationSettingsPersistenceTests.swift` — cover the new field.

---

## Task 1: `shortTapAction` setting

**Files:**
- Modify: `Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift`
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/DictationSettingsPersistenceTests.swift`

**Interfaces:**
- Produces: `DictationSettings.ShortTapAction` (`enum { case oneShot, autoListening }`, `String`-`Codable`), `DictationSettings.shortTapAction: ShortTapAction` (default `.oneShot`).

- [ ] **Step 1: Write the failing test**

Append to `DictationSettingsPersistenceTests.swift` (Swift Testing style, matching the existing file):

```swift
@Test func shortTapActionDefaultsToOneShot() {
    #expect(DictationSettings().shortTapAction == .oneShot)
}

@Test func shortTapActionRoundTrips() throws {
    var s = DictationSettings()
    s.shortTapAction = .autoListening
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(DictationSettings.self, from: data)
    #expect(decoded.shortTapAction == .autoListening)
}

@Test func shortTapActionAbsentDecodesToOneShot() throws {
    // A pre-auto-dictation blob has no shortTapAction key.
    let json = """
    {"enabled":false,"trigger":"rightCommand","holdThresholdMs":250,
     "model":"whisper-large-v3-turbo","insertMode":"autoInsert",
     "showOverlay":false,"keepAudio":false,"streamLive":false,"language":"en"}
    """
    let decoded = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    #expect(decoded.shortTapAction == .oneShot)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettingsPersistenceTests`
Expected: FAIL — `shortTapAction` is not a member of `DictationSettings`.

- [ ] **Step 3: Add the enum, property, init param, and tolerant decode**

In `DictationSettings.swift`, add the enum inside the struct (top of the type):

```swift
public enum ShortTapAction: String, Codable, Sendable {
    case oneShot        // tap toggles a single capture (default, today's behaviour)
    case autoListening  // tap toggles the always-on auto-dictation loop
}
```

Add the stored property alongside the others:

```swift
public var shortTapAction: ShortTapAction
```

Add the parameter to the memberwise `init` (default `.oneShot`) and assign it:

```swift
    showOverlay: Bool = false,
    keepAudio: Bool = false,
    streamLive: Bool = false,
    shortTapAction: ShortTapAction = .oneShot,
    language: String = "en"
) {
    ...
    self.shortTapAction = shortTapAction
    self.language = language
}
```

Add the tolerant decode in `init(from:)` (mirror the `streamLive`/`language` pattern):

```swift
shortTapAction = try c.decodeIfPresent(ShortTapAction.self, forKey: .shortTapAction) ?? .oneShot
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationSettingsPersistenceTests`
Expected: PASS (all three new tests + existing).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift \
        Packages/AudioPipeline/Tests/AppSettingsTests/DictationSettingsPersistenceTests.swift
git commit -m "feat(dictation): add shortTapAction setting (oneShot | autoListening)"
```

---

## Task 2: `AutoDictationSegmenter` (pure state machine)

**Files:**
- Create: `Packages/AudioPipeline/Sources/DictationCore/AutoDictationSegmenter.swift`
- Test: `Packages/AudioPipeline/Tests/DictationCoreTests/AutoDictationSegmenterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `AutoDictationSegmenter.VoiceEvent` = `enum { case none, speechStart, speechEnd }`
  - `AutoDictationSegmenter.Action` = `enum { case ignore, beginSegment, appendFrame, finalizeSegment, rolloverSegment }`
  - `init(maxSegmentFrames: Int)`
  - `mutating func step(_ event: VoiceEvent) -> Action`

- [ ] **Step 1: Write the failing test**

Create `AutoDictationSegmenterTests.swift`:

```swift
import Testing
@testable import DictationCore

struct AutoDictationSegmenterTests {
    @Test func silenceWhileIdleIsIgnored() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        #expect(s.step(.none) == .ignore)
    }

    @Test func speechStartBeginsSegment() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        #expect(s.step(.speechStart) == .beginSegment)
    }

    @Test func framesWhileCapturingAppend() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        _ = s.step(.speechStart)
        #expect(s.step(.none) == .appendFrame)
        #expect(s.step(.none) == .appendFrame)
    }

    @Test func speechEndFinalizes() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        _ = s.step(.speechStart)
        _ = s.step(.none)
        #expect(s.step(.speechEnd) == .finalizeSegment)
        // Back to idle: further silence ignored.
        #expect(s.step(.none) == .ignore)
    }

    @Test func maxCutRollsOverInsteadOfAppending() {
        // maxSegmentFrames = 3: beginSegment counts as frame 1, then 2 appends,
        // the 3rd frame while capturing hits the cap and rolls over.
        var s = AutoDictationSegmenter(maxSegmentFrames: 3)
        #expect(s.step(.speechStart) == .beginSegment) // frame 1
        #expect(s.step(.none) == .appendFrame)         // frame 2
        #expect(s.step(.none) == .rolloverSegment)     // frame 3 → cap → new segment (frame 1)
        #expect(s.step(.none) == .appendFrame)         // frame 2 of new segment
    }

    @Test func speechEndTakesPriorityOverMaxCut() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 2)
        _ = s.step(.speechStart)                        // frame 1
        #expect(s.step(.speechEnd) == .finalizeSegment) // end wins even though cap would hit
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AutoDictationSegmenterTests`
Expected: FAIL — `AutoDictationSegmenter` is undefined.

- [ ] **Step 3: Write the implementation**

Create `AutoDictationSegmenter.swift`:

```swift
/// Pure segment boundary logic for auto-dictation. Consumes VAD events (one per
/// audio frame) and decides what the controller should do with that frame.
///
/// FluidAudio's streaming VAD already enforces the endpoint pause
/// (`minSilenceDuration`) and speech-onset threshold, so this type only adds the
/// max-segment force-cut and tracks idle/capturing. It is deliberately pure so it
/// can be exhaustively unit-tested without audio or a model.
public struct AutoDictationSegmenter: Sendable {
    public enum VoiceEvent: Sendable, Equatable { case none, speechStart, speechEnd }

    public enum Action: Sendable, Equatable {
        case ignore              // idle, no speech: drop the frame
        case beginSegment        // start a new segment; controller writes pre-roll + this frame
        case appendFrame         // capturing: write this frame to the current segment
        case finalizeSegment     // endpoint reached: close + transcribe; now idle
        case rolloverSegment     // max-cut: close current (transcribe), open a new one, write this frame
    }

    private enum State { case idle, capturing }
    private var state: State = .idle
    private var framesInSegment = 0
    private let maxSegmentFrames: Int

    public init(maxSegmentFrames: Int) {
        precondition(maxSegmentFrames > 0, "maxSegmentFrames must be positive")
        self.maxSegmentFrames = maxSegmentFrames
    }

    public mutating func step(_ event: VoiceEvent) -> Action {
        switch state {
        case .idle:
            guard event == .speechStart else { return .ignore }
            state = .capturing
            framesInSegment = 1
            return .beginSegment
        case .capturing:
            if event == .speechEnd {
                state = .idle
                framesInSegment = 0
                return .finalizeSegment
            }
            framesInSegment += 1
            if framesInSegment >= maxSegmentFrames {
                framesInSegment = 1   // this frame starts the fresh segment
                return .rolloverSegment
            }
            return .appendFrame
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AutoDictationSegmenterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/DictationCore/AutoDictationSegmenter.swift \
        Packages/AudioPipeline/Tests/DictationCoreTests/AutoDictationSegmenterTests.swift
git commit -m "feat(dictation): pure AutoDictationSegmenter (idle/capturing + max-cut)"
```

---

## Task 3: `FrameSlicer` (pure fixed-size framing)

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/FrameSlicer.swift`
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/FrameSlicerTests.swift`

**Interfaces:**
- Produces: `FrameSlicer(frameSize: Int)`, `mutating func push(_ samples: [Float]) -> [[Float]]` (returns any complete frames of exactly `frameSize`; buffers the remainder).

- [ ] **Step 1: Write the failing test**

Create `FrameSlicerTests.swift`:

```swift
import Testing
@testable import RecordingCore

struct FrameSlicerTests {
    @Test func emitsNothingUntilAFullFrame() {
        var slicer = FrameSlicer(frameSize: 4)
        #expect(slicer.push([1, 2, 3]).isEmpty)
    }

    @Test func emitsOneFrameWhenExactlyFull() {
        var slicer = FrameSlicer(frameSize: 4)
        let out = slicer.push([1, 2, 3, 4])
        #expect(out == [[1, 2, 3, 4]])
    }

    @Test func emitsMultipleFramesAndBuffersRemainder() {
        var slicer = FrameSlicer(frameSize: 2)
        let out = slicer.push([1, 2, 3, 4, 5])
        #expect(out == [[1, 2], [3, 4]])
        // 5 is buffered; a single more sample completes the next frame.
        #expect(slicer.push([6]) == [[5, 6]])
    }

    @Test func accumulatesAcrossPushes() {
        var slicer = FrameSlicer(frameSize: 3)
        #expect(slicer.push([1]).isEmpty)
        #expect(slicer.push([2]).isEmpty)
        #expect(slicer.push([3]) == [[1, 2, 3]])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FrameSlicerTests`
Expected: FAIL — `FrameSlicer` is undefined.

- [ ] **Step 3: Write the implementation**

Create `FrameSlicer.swift`:

```swift
/// Buffers a running stream of samples and emits fixed-size frames. The audio
/// tap delivers variable-length buffers; the VAD requires exactly `frameSize`
/// samples per call, so this slices the stream into uniform frames and carries
/// the remainder to the next push. Pure and Sendable for unit testing.
public struct FrameSlicer: Sendable {
    private var buffer: [Float] = []
    private let frameSize: Int

    public init(frameSize: Int) {
        precondition(frameSize > 0, "frameSize must be positive")
        self.frameSize = frameSize
    }

    /// Append `samples` and return every complete frame now available.
    public mutating func push(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        var frames: [[Float]] = []
        while buffer.count >= frameSize {
            frames.append(Array(buffer[0..<frameSize]))
            buffer.removeFirst(frameSize)
        }
        return frames
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FrameSlicerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/FrameSlicer.swift \
        Packages/AudioPipeline/Tests/RecordingCoreTests/FrameSlicerTests.swift
git commit -m "feat(dictation): pure FrameSlicer for fixed-size VAD frames"
```

---

## Task 4: `SegmentAudioWriter` (Float samples → 16 kHz mono WAV)

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/SegmentAudioWriter.swift`
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/SegmentAudioWriterTests.swift`

**Interfaces:**
- Produces: `enum SegmentAudioWriter { static func write(_ samples: [Float], to url: URL) throws }` (writes 16 kHz mono Int16 WAV; `nonisolated`/static so it can run off the main actor).

- [ ] **Step 1: Write the failing test**

Create `SegmentAudioWriterTests.swift`:

```swift
import Testing
import AVFoundation
@testable import RecordingCore

struct SegmentAudioWriterTests {
    @Test func writesReadableWavWithExpectedFrameCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = (0..<8000).map { Float(sin(Double($0) * 0.05)) } // 0.5 s @ 16 kHz
        try SegmentAudioWriter.write(samples, to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 8000)
    }

    @Test func emptySamplesThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString).wav")
        #expect(throws: (any Error).self) { try SegmentAudioWriter.write([], to: url) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SegmentAudioWriterTests`
Expected: FAIL — `SegmentAudioWriter` is undefined.

- [ ] **Step 3: Write the implementation**

Create `SegmentAudioWriter.swift`:

```swift
import AVFoundation

/// Writes in-memory 16 kHz mono Float samples to a WAV file the local
/// transcription engines can read. Static + nonisolated so the controller can
/// call it off the main actor. Mirrors DictationWAVWriter's Int16/16 kHz output
/// format and its 4-arg AVAudioFile init (a 2-arg init leaves processingFormat
/// float32/deinterleaved and aborts on an Int16 write).
public enum SegmentAudioWriter {
    public enum WriterError: Error, Sendable { case empty, formatUnavailable, bufferAllocationFailed }

    public static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw WriterError.empty }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000,
            channels: 1, interleaved: true) else {
            throw WriterError.formatUnavailable
        }
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: outFormat.commonFormat, interleaved: outFormat.isInterleaved)

        // Source Float samples must be converted to Int16. Build a float buffer,
        // then convert to the Int16 output format for the write.
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let floatBuffer = AVAudioPCMBuffer(
                pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: floatFormat, to: outFormat) else {
            throw WriterError.bufferAllocationFailed
        }
        floatBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            floatBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        guard let intBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw WriterError.bufferAllocationFailed
        }
        var err: NSError?
        var fed = false
        converter.convert(to: intBuffer, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return floatBuffer
        }
        if let err { throw err }
        try file.write(from: intBuffer)
        // file is released here → AVAudioFile finalizes the WAV container on disk.
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SegmentAudioWriterTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/SegmentAudioWriter.swift \
        Packages/AudioPipeline/Tests/RecordingCoreTests/SegmentAudioWriterTests.swift
git commit -m "feat(dictation): SegmentAudioWriter (Float samples -> 16kHz mono WAV)"
```

---

## Task 5: `ContinuousMicTap` (always-on tap → Float frames)

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/ContinuousMicTap.swift`

**Interfaces:**
- Consumes: `FrameSlicer` (Task 3).
- Produces: `final class ContinuousMicTap` with `init(frameSize: Int, onFrame: @escaping @Sendable ([Float]) -> Void) throws`, `func start() throws`, `func stop()`. Delivers exactly `frameSize`-length 16 kHz mono Float frames to `onFrame` off the main thread.

No unit test — requires a live mic. Verified by the app-hosted smoke in Task 8 and by compiling. (Its testable framing logic lives in `FrameSlicer`, Task 3.)

- [ ] **Step 1: Write the implementation**

Create `ContinuousMicTap.swift`:

```swift
import AVFoundation

/// Always-on mic capture for auto-dictation. Installs one AVAudioEngine tap,
/// converts hardware-format buffers to 16 kHz mono Float32, and delivers fixed
/// `frameSize`-sample frames via `onFrame` (called on the audio thread). The
/// frame callback is `@Sendable` and hops isolation itself — this type inherits
/// no actor isolation for the tap closure (SWIFT_DEFAULT_ACTOR_ISOLATION is
/// MainActor, so the closure is explicitly @Sendable to stay off-main).
public final class ContinuousMicTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let onFrame: @Sendable ([Float]) -> Void

    // Framing state is only touched inside the serial tap callback.
    private var slicer: FrameSlicer

    public init(frameSize: Int, onFrame: @escaping @Sendable ([Float]) -> Void) throws {
        self.onFrame = onFrame
        self.slicer = FrameSlicer(frameSize: frameSize)
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw DictationRecorderError.noInput
        }
        self.inputFormat = input
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: input, to: out) else {
            throw DictationRecorderError.formatUnavailable
        }
        self.outputFormat = out
        self.converter = conv
    }

    public func start() throws {
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 4_096, format: inputFormat
        ) { @Sendable [weak self] buffer, _ in
            guard let self, let copy = buffer.deepCopy() else { return }
            self.handle(copy)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        final class Once: @unchecked Sendable { var buf: AVAudioPCMBuffer? }
        let once = Once(); once.buf = buffer
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            guard let b = once.buf else { inStatus.pointee = .noDataNow; return nil }
            once.buf = nil
            inStatus.pointee = .haveData
            return b
        }
        guard status != .error, err == nil, out.frameLength > 0,
              let ch = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        for frame in slicer.push(samples) { onFrame(frame) }
    }
}
```

Note: `buffer.deepCopy()` and `DictationRecorderError` already exist in RecordingCore (used by `DictationRecorder`).

- [ ] **Step 2: Build the package to verify it compiles**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: Build succeeds (no strict-concurrency errors on the tap closure).

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/ContinuousMicTap.swift
git commit -m "feat(dictation): ContinuousMicTap (always-on 16kHz mono Float frames)"
```

---

## Task 6: `StreamingVoiceDetector` (FluidAudio VAD wrapper)

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/StreamingVoiceDetector.swift`

**Interfaces:**
- Consumes: FluidAudio `VadManager`, `VadStreamState`, `VadSegmentationConfig`, `VadStreamResult` (already in the dependency).
- Produces:
  - `enum VoiceActivityEvent: Sendable, Equatable { case none, speechStart, speechEnd }`
  - `actor StreamingVoiceDetector` with:
    - `init(modelDirectory: URL, endpointSilence: TimeInterval = 0.6, threshold: Float = 0.85)`
    - `func prepare() async throws` (loads/downloads the Silero VAD model; idempotent)
    - `func reset()` (fresh stream state for a new session)
    - `func detect(_ frame: [Float]) async throws -> VoiceActivityEvent`
  - `static let frameSize = VadManager.chunkSize` (4096)

No unit test (needs the Silero VAD CoreML model + network on first run). Exercised by the gated app-hosted smoke in Task 8.

- [ ] **Step 1: Write the implementation**

Create `StreamingVoiceDetector.swift`:

```swift
import Foundation
import FluidAudio

/// Speech-onset / endpoint events for auto-dictation. Engine-agnostic wrapper so
/// the app never imports FluidAudio directly.
public enum VoiceActivityEvent: Sendable, Equatable { case none, speechStart, speechEnd }

/// Wraps FluidAudio's streaming Silero VAD. Feed it fixed 4096-sample (256 ms)
/// 16 kHz mono Float frames; it emits speechStart when speech begins and
/// speechEnd after `endpointSilence` of trailing silence (Silero hysteresis).
public actor StreamingVoiceDetector {
    /// Frames must be exactly this many samples (256 ms @ 16 kHz).
    public static let frameSize = VadManager.chunkSize   // 4096

    private let modelDirectory: URL
    private let segConfig: VadSegmentationConfig
    private let vadConfig: VadConfig

    private var manager: VadManager?
    private var state: VadStreamState = .initial()

    public init(modelDirectory: URL, endpointSilence: TimeInterval = 0.6, threshold: Float = 0.85) {
        self.modelDirectory = modelDirectory
        self.vadConfig = VadConfig(defaultThreshold: threshold)
        // maxSpeechDuration is unused by the streaming path (the segmenter owns
        // max-cut); minSpeechDuration is likewise not enforced streaming, so the
        // controller applies its own min-length discard.
        self.segConfig = VadSegmentationConfig(
            minSilenceDuration: endpointSilence,
            speechPadding: 0.1)
    }

    /// Load (downloading if needed) the Silero VAD model. Idempotent.
    public func prepare() async throws {
        guard manager == nil else { return }
        manager = try await VadManager(config: vadConfig, modelDirectory: modelDirectory)
    }

    /// Start a fresh utterance stream (call on each toggle-on).
    public func reset() { state = .initial() }

    /// Process one 4096-sample frame; returns the boundary event, if any.
    public func detect(_ frame: [Float]) async throws -> VoiceActivityEvent {
        guard let manager else { throw VadError.notInitialized }
        let result = try await manager.processStreamingChunk(
            frame, state: state, config: segConfig)
        state = result.state
        switch result.event?.kind {
        case .some(.speechStart): return .speechStart
        case .some(.speechEnd):   return .speechEnd
        case .none:               return .none
        }
    }
}
```

- [ ] **Step 2: Build the package to verify it compiles**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: Build succeeds. (Confirms the FluidAudio VAD symbols and signatures used above match 0.15.4.)

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/StreamingVoiceDetector.swift
git commit -m "feat(dictation): StreamingVoiceDetector wrapping FluidAudio Silero VAD"
```

---

## Task 7: `AutoDictationController` (the loop)

**Files:**
- Create: `Amanuensis/Dictation/AutoDictationController.swift`

**Interfaces:**
- Consumes: `ContinuousMicTap` (T5), `SegmentAudioWriter` (T4), `StreamingVoiceDetector` + `VoiceActivityEvent` (T6), `AutoDictationSegmenter` (T2), `DictationTempStore`, `BatchTranscriber`, `TextInserter`, `DictationOverlayController`, `LocalModelSupport`, `AppSettings`, `Provider.localID`, `Provider.localPlaceholder`, `Job`, `JobShape.localTranscription`.
- Produces: `@MainActor @Observable final class AutoDictationController` with:
  - `init(settings:keychain:handlers:ensureLocalModelResident:log:vadModelDirectory:)`
  - `private(set) var isRunning: Bool`
  - `func toggle()`, `func stop()`

No unit test here (mic + model + AppKit). Covered by the gated app-hosted smoke in Task 8.

- [ ] **Step 1: Write the implementation**

Create `AutoDictationController.swift`:

```swift
import Foundation
import AppKit
import AVFoundation
import DictationCore
import LocalTranscription
import RecordingCore
import AudioPipelineJobs
import AppSettings

/// Drives always-on auto-dictation: mic tap → VAD → segmenter → per-utterance
/// local transcription → append into the focused field. Toggled on/off by
/// DictationCoordinator when `shortTapAction == .autoListening`.
@MainActor
@Observable
final class AutoDictationController {
    private(set) var isRunning = false

    private let settings: AppSettings
    private let keychain: any KeychainProviding
    private let handlers: [JobShape: any AudioJobSending]
    private let ensureLocalModelResident: (String) async -> Void
    private let log: (String) -> Void

    private let detector: StreamingVoiceDetector
    private let tempStore = DictationTempStore()
    private let overlay = DictationOverlayController()

    // Tuning. One frame = 4096 samples = 256 ms @ 16 kHz.
    private static let frameSamples = StreamingVoiceDetector.frameSize
    private static let maxSegmentFrames = 59          // ~15 s
    private static let preRollFrames = 2              // ~512 ms
    private static let minSegmentSamples = 4_000      // ~250 ms: discard shorter

    private var tap: ContinuousMicTap?
    private var frameStream: AsyncStream<[Float]>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var segmentStream: AsyncStream<[Float]>.Continuation?
    private var transcribeTask: Task<Void, Never>?

    // Consumer-loop state (main-actor isolated; only touched in consumerTask).
    private var segmenter = AutoDictationSegmenter(maxSegmentFrames: Self.maxSegmentFrames)
    private var preRoll: [[Float]] = []
    private var current: [Float] = []

    init(settings: AppSettings,
         keychain: any KeychainProviding,
         handlers: [JobShape: any AudioJobSending],
         ensureLocalModelResident: @escaping (String) async -> Void,
         log: @escaping (String) -> Void,
         vadModelDirectory: URL) {
        self.settings = settings
        self.keychain = keychain
        self.handlers = handlers
        self.ensureLocalModelResident = ensureLocalModelResident
        self.log = log
        self.detector = StreamingVoiceDetector(modelDirectory: vadModelDirectory)
    }

    func toggle() { isRunning ? stop() : start() }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tap?.stop(); tap = nil
        frameStream?.finish(); frameStream = nil
        consumerTask?.cancel(); consumerTask = nil
        segmentStream?.finish(); segmentStream = nil   // lets the transcribe loop drain + exit
        preRoll.removeAll(); current.removeAll()
        segmenter = AutoDictationSegmenter(maxSegmentFrames: Self.maxSegmentFrames)
        overlay.update(phase: .idle, enabled: settings.dictation.showOverlay)
    }

    private func start() {
        guard !isRunning else { return }
        // Preflight: local + Apple Silicon only.
        guard TranscriptionSource(providerID: settings.dictation.providerID) == .local,
              LocalModelSupport.isSupported else {
            overlay.flash("Auto-dictation needs a local model on Apple Silicon")
            return
        }
        isRunning = true
        overlay.setModelLoading(true)
        overlay.update(phase: .listening, enabled: settings.dictation.showOverlay)

        // Serial transcription consumer: one segment at a time, in order.
        let (segStream, segCont) = AsyncStream<[Float]>.makeStream()
        segmentStream = segCont
        transcribeTask = Task { [weak self] in
            for await samples in segStream { await self?.transcribeAndInsert(samples) }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.detector.prepare()
                await self.detector.reset()
                await self.ensureLocalModelResident(self.settings.dictation.model)
            } catch {
                self.log("Auto-dictation: VAD prepare failed: \(error.localizedDescription)")
                self.overlay.flash("Couldn't start auto-dictation")
                self.stop()
                return
            }
            self.overlay.setModelLoading(false)
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard isRunning else { return }
        let (stream, cont) = AsyncStream<[Float]>.makeStream(
            bufferingPolicy: .bufferingNewest(64))
        frameStream = cont
        do {
            let tap = try ContinuousMicTap(frameSize: Self.frameSamples) { [cont] frame in
                cont.yield(frame)   // audio thread → stream; consumer hops to main
            }
            try tap.start()
            self.tap = tap
        } catch {
            log("Auto-dictation: mic unavailable: \(error.localizedDescription)")
            overlay.flash("Mic unavailable")
            stop()
            return
        }
        consumerTask = Task { [weak self] in
            for await frame in stream { await self?.consume(frame) }
        }
    }

    private func consume(_ frame: [Float]) async {
        // Maintain a rolling pre-roll so the first word isn't clipped.
        preRoll.append(frame)
        if preRoll.count > Self.preRollFrames { preRoll.removeFirst() }

        let event: VoiceActivityEvent = (try? await detector.detect(frame)) ?? .none
        guard isRunning else { return }
        let mapped: AutoDictationSegmenter.VoiceEvent
        switch event {
        case .speechStart: mapped = .speechStart
        case .speechEnd:   mapped = .speechEnd
        case .none:        mapped = .none
        }

        switch segmenter.step(mapped) {
        case .ignore:
            break
        case .beginSegment:
            current = preRoll.flatMap { $0 }   // include pre-roll + this frame
            overlay.update(phase: .listening, enabled: settings.dictation.showOverlay)
        case .appendFrame:
            current.append(contentsOf: frame)
        case .finalizeSegment:
            finalizeCurrent()
        case .rolloverSegment:
            finalizeCurrent()
            current = frame                    // this frame opens the next segment
        }
    }

    private func finalizeCurrent() {
        let samples = current
        current.removeAll()
        guard samples.count >= Self.minSegmentSamples else { return }   // drop coughs/clicks
        segmentStream?.yield(samples)
        overlay.update(phase: .transcribing, enabled: settings.dictation.showOverlay)
    }

    private func transcribeAndInsert(_ samples: [Float]) async {
        let url = tempStore.newCaptureURL()
        defer { tempStore.delete(url) }
        do {
            try await Task.detached { try SegmentAudioWriter.write(samples, to: url) }.value
        } catch {
            log("Auto-dictation: segment write failed: \(error.localizedDescription)")
            return
        }
        let job = Job(
            name: "Dictation", providerID: Provider.localID,
            model: settings.dictation.model,
            fields: ["language": settings.dictation.language], outputExt: "txt")
        let transcriber = BatchTranscriber(
            job: job, provider: .localPlaceholder,
            shape: .localTranscription, keychain: keychain, handlers: handlers)
        let box = TranscriptBox()
        do {
            try await transcriber.transcribe(
                audioFile: url, onPartial: { _ in }, onFinal: { box.value = $0 })
        } catch {
            log("Auto-dictation: transcription failed: \(error.localizedDescription)")
            if isRunning { overlay.update(phase: .listening, enabled: settings.dictation.showOverlay) }
            return
        }
        let text = box.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            _ = TextInserter().insert(" " + text, mode: settings.dictation.insertMode)
        }
        if isRunning { overlay.update(phase: .listening, enabled: settings.dictation.showOverlay) }
    }
}

/// Single-writer transcript box (BatchTranscriber calls onFinal once,
/// synchronously, before returning — the await is the happens-before barrier).
private final class TranscriptBox: @unchecked Sendable { nonisolated(unsafe) var value = "" }
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds. (New file is auto-picked-up by the synchronized group; no pbxproj edit.)

- [ ] **Step 3: Commit**

```bash
git add Amanuensis/Dictation/AutoDictationController.swift
git commit -m "feat(dictation): AutoDictationController always-on loop"
```

---

## Task 8: Wire the trigger routing (DictationCoordinator + AppCoordinator)

**Files:**
- Modify: `Amanuensis/Dictation/DictationCoordinator.swift`
- Modify: `Amanuensis/AppCoordinator.swift`

**Interfaces:**
- Consumes: `AutoDictationController` (T7) with `isRunning`, `toggle()`, `stop()`.
- Produces: `DictationCoordinator.init(... autoController: AutoDictationController ...)`; tap routes on `settings.dictation.shortTapAction`; holds suppressed while `autoController.isRunning`.

- [ ] **Step 1: Add the injected controller to DictationCoordinator**

In `DictationCoordinator.swift`, add a stored property and init param. Add after the other `private let` deps:

```swift
    private let autoController: AutoDictationController
```

Add the parameter to `init` (place it right after `isLocalModelResident:`), and assign it:

```swift
         isLocalModelResident: @escaping (String) -> Bool = { _ in true },
         autoController: AutoDictationController,
         log: @escaping (String) -> Void) {
        ...
        self.isLocalModelResident = isLocalModelResident
        self.autoController = autoController
        self.log = log
```

- [ ] **Step 2: Split `.toggle` routing and suppress holds while auto runs**

In `applyGesture(_:)`, replace the combined `.toggle, .pttStart` / `.pttEnd` cases:

```swift
        case .toggle:
            switch settings.dictation.shortTapAction {
            case .oneShot:       applyAction(machine.startOrToggle())
            case .autoListening: autoController.toggle()
            }
        case .pttStart:
            if autoController.isRunning { break }   // loop already captures everything
            applyAction(machine.startOrToggle())
        case .pttEnd:
            if autoController.isRunning { break }
            applyAction(machine.release())
```

- [ ] **Step 3: Stop the auto loop when dictation is disabled or the tap action changes away**

In `settingsChanged()`, after the existing enable/disable handling, add:

```swift
        if !settings.dictation.enabled || settings.dictation.shortTapAction != .autoListening {
            autoController.stop()
        }
```

- [ ] **Step 4: Construct and inject the controller in AppCoordinator**

In `AppCoordinator.swift`, add a stored property near `let dictation: DictationCoordinator`:

```swift
    let autoDictation: AutoDictationController
```

Immediately before the `self.dictation = DictationCoordinator(...)` construction, build the controller (reusing the same closures):

```swift
        let autoDictation = AutoDictationController(
            settings: settings,
            keychain: keychain,
            handlers: localHandlers,
            ensureLocalModelResident: { [localModelsStore] id in await localModelsStore.preload(modelID: id) },
            log: { [logs] message in logs.log(.error, message, category: .recording) },
            vadModelDirectory: (try? ModelStorage.base().appendingPathComponent("FluidAudioVAD", isDirectory: true))
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("FluidAudioVAD", isDirectory: true))
        self.autoDictation = autoDictation
```

Then pass it into the `DictationCoordinator(...)` init:

```swift
            isLocalModelResident: { [localModelsStore] id in localModelsStore.residentModelID == id },
            autoController: autoDictation,
            log: { [logs] message in logs.log(.error, message, category: .recording) }
        )
```

Add `import LocalTranscription` to `AppCoordinator.swift` if not already present (needed for `ModelStorage`). Verify with:

```bash
rg -n "^import " Amanuensis/AppCoordinator.swift
```

- [ ] **Step 5: Build the app to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Amanuensis/Dictation/DictationCoordinator.swift Amanuensis/AppCoordinator.swift
git commit -m "feat(dictation): route short-tap to auto loop; inject AutoDictationController"
```

---

## Task 9: Settings UI picker + menu-bar indicator

**Files:**
- Modify: `Amanuensis/UI/Dictation/DictationView.swift`
- Modify: `Amanuensis/UI/DictationMenuBarLabel.swift`

**Interfaces:**
- Consumes: `settings.dictation.shortTapAction`, `coordinator.dictation.settingsChanged()`, `coordinator.autoDictation.isRunning` (T7/T8).

- [ ] **Step 1: Add the picker**

In `DictationView.swift`, directly after the "Trigger key" Picker block (the one with `.onChange(of: settings.dictation.trigger)`), add:

```swift
                Picker("Short tap", selection: $settings.dictation.shortTapAction) {
                    Text("Start / stop one capture").tag(DictationSettings.ShortTapAction.oneShot)
                    Text("Toggle auto-listening").tag(DictationSettings.ShortTapAction.autoListening)
                }
                .onChange(of: settings.dictation.shortTapAction) { _, _ in
                    coordinator.dictation.settingsChanged()
                }
                .help("With auto-listening, a tap of the trigger turns hands-free dictation on or off. Hold still works as push-to-talk.")
```

`DictationView.swift` already imports `DictationCore` (it uses `DictationSettings`), so `ShortTapAction` resolves without a new import.

- [ ] **Step 2: Add a distinct menu-bar indicator while the auto loop runs**

In `DictationMenuBarLabel.swift`, add an `else if` branch after the existing dictation-phase branch (auto mode leaves `dictation.phase == .idle`, so without this it would show the plain idle icon):

```swift
        if coordinator.dictation.phase != .idle {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else if coordinator.autoDictation.isRunning {
            Image(systemName: "mic.fill")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else if coordinator.isRecording {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
        } else {
            Image(systemName: "waveform.circle")
                .symbolRenderingMode(.hierarchical)
        }
```

`AutoDictationController` is `@Observable`, so SwiftUI re-renders the label when `isRunning` flips.

- [ ] **Step 3: Build the app to verify it compiles**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/Dictation/DictationView.swift Amanuensis/UI/DictationMenuBarLabel.swift
git commit -m "feat(dictation): short-tap action picker + auto-listening menu-bar icon"
```

---

## Task 10: End-to-end verification

**Files:** none (manual + gated smoke).

- [ ] **Step 1: Full SPM suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (all suites, including the new `AutoDictationSegmenterTests`, `FrameSlicerTests`, `SegmentAudioWriterTests`, `DictationSettingsPersistenceTests`).

- [ ] **Step 2: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: Build succeeds.

- [ ] **Step 3: Manual smoke (real machine, Apple Silicon)**

1. Launch the built app. In Settings → Dictation: enable dictation, set Provider to a local model (e.g. Parakeet TDT-CTC 110M), set **Short tap = Toggle auto-listening**.
2. Focus a text field (e.g. a terminal or note). Tap the trigger once. (First run downloads the ~small Silero VAD model — expect a brief "Loading model…" overlay.)
3. Speak a sentence, pause. Confirm the sentence is typed into the field after the pause (~0.6 s endpoint + transcription time). Speak again; confirm it appends.
4. Stay silent with background noise (fan/keyboard/music): confirm nothing is typed.
5. Tap the trigger again: confirm the mic indicator goes off and nothing more is typed.
6. Switch **Short tap = Start / stop one capture**: confirm a tap now does a single one-shot capture (old behaviour) and hold-to-talk still works.

Capture logs if anything misfires:
`./scripts/log-helper.sh show --last 5m --info --predicate 'process == "Amanuensis"'`

- [ ] **Step 4: Final commit (if any doc/tuning tweaks)**

```bash
git add -A && git commit -m "chore(dictation): auto-dictation end-to-end verification"
```

---

## Notes for the implementer

- **Do not** add engine-specific transcription code in the loop — it must stay `BatchTranscriber` (local shape) so Parakeet/WhisperKit/Indic all work unchanged.
- **Tuning constants** (`maxSegmentFrames`, `preRollFrames`, `minSegmentSamples`, `endpointSilence`, `threshold`) live in `AutoDictationController` / `StreamingVoiceDetector` as internal defaults, not settings, per the spec. Adjust only if manual smoke shows clipping or over-triggering.
- **VAD model** downloads on first `prepare()` into `<AppSupport>/Amanuensis/Models/FluidAudioVAD/Models/…` (sandbox container). Requires network once; handled by the prepare-failure path.
- **Mic indicator stays lit** the whole time the loop is on — expected, per the spec.
```
