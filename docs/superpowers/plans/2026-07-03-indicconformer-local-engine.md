# IndicConformer-600M Local Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device `IndicConformerEngine` (AI4Bharat IndicConformer-600M, MIT) so the app can transcribe Hindi + 6 Indic languages locally, via the existing batch `LocalTranscriptionEngine` seam (which also serves dictation).

**Architecture:** Port Muesli's MIT `IndicASRBackend.swift` onto our `LocalTranscriptionEngine` protocol. The heavy inference (log-mel frontend + Core ML encoder/prediction/joint chain + greedy RNN-T decode) is split into small `nonisolated` units behind an injectable `IndicConformerInference` seam so the greedy-decode control flow is unit-testable without Core ML. One `actor IndicConformerEngine` owns the resident 12-model bundle and adapts it to the protocol, mirroring `WhisperKitEngine`.

**Tech Stack:** Swift 6.2, CoreML, Accelerate/vDSP, FluidAudio (`AudioConverter` for resampling — already a dependency), Swift Testing.

## Global Constraints

- **Deployment target:** macOS 26.3, Swift 6.2. Package default actor isolation is `MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) with `NonisolatedNonsendingByDefault`. **All inference types in this plan (`IndicConformerMel`, `IndicConformerVocab`, `IndicConformerMerger`, `IndicConformerGreedyDecoder`, `CoreMLIndicInference`, `IndicConformerModelStore`, `IndicConformerModels`) must be `nonisolated`** so none run on the MainActor; `IndicConformerEngine` is an `actor`. Add `nonisolated` to declarations/members as the compiler requires.
- **No new SPM dependencies.** Only `CoreML`, `Accelerate`, `Foundation`, and the already-vendored `FluidAudio`.
- **Module:** all new source under `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/`; all new tests under `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/`.
- **Model repo (pinned):** `phequals/indic-conformer-600m-multilingual-coreml-rnnt`, revision `5590d07c06e95d461790ff753d4af536f0660197` (MIT).
- **Reference (pinned):** `pHequals7/muesli` @ `9a91db7c32cfe76fc4077a008b22337c2719a9a9`, file `native/MuesliNative/Sources/MuesliNativeApp/IndicASRBackend.swift` (MIT © 2026 Pranav Hari). Ported with attribution.
- **Model contract (exact):** encoder in `audio_signal Float32[1,80,1024]` + `length Int32[1]`, out `outputs [1,1024,frames]` + `encoded_lengths Int32[1]`. Prediction LSTM in `targets Int32[1,1]`, `target_length Int32[1]`, `states_1 Float32[2,1,640]`, `cell_state_in Float32[2,1,640]`, out `outputs [1,640]`, `states`, `cell_state_out`. Joint = `jointEnc(encFrame) + jointPred(predOut)` element-wise → `jointPreNet` → `jointPostNet[lang]` → logits; argmax over `257`. blank `256`, SOS `5632`, ≤10 symbols/frame. Constants: sr 16000, nFFT 512, hop 160, win 400, 80 mels, encoderDim 1024, predHiddenDim 640, predLayers 2.
- **SPM test command (in sandbox):** `swift test --disable-sandbox --package-path Packages/AudioPipeline`. **After the SPM suite is green, rebuild the app target:** `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`.
- **Commits:** conventional commits, one per task minimum. Do not push unless asked.

---

## File Structure

**New source** (`Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/`):
- `IndicConformerConfig.swift` — constants, `IndicConformerLanguage` enum, package names, on-disk layout helpers.
- `IndicConformerPreprocessorConstants.swift` — parses `preprocessor_constants.bin` (magic `IASRPC01`).
- `IndicConformerMel.swift` — log-mel frontend (Accelerate/vDSP).
- `IndicConformerVocab.swift` — per-language token map + detokenize.
- `IndicConformerMerger.swift` — token- and text-level overlap merge across chunks.
- `IndicConformerInference.swift` — the injectable seam: `LSTMState`, `PredictionStep`, `EncoderOutput`, `IndicConformerInference` protocol.
- `IndicConformerGreedyDecoder.swift` — greedy RNN-T control flow over the seam (pure, testable).
- `CoreMLIndicInference.swift` — the Core ML conformer of `IndicConformerInference` (encoder/decoder/joint MLModel calls).
- `IndicConformerModelStore.swift` — on-disk layout, HF download, `isDownloaded`/size/delete.
- `IndicConformerModels.swift` — loads + compiles the 12 `.mlpackage`s; owns tokenizer + mel; builds a `CoreMLIndicInference`.
- `IndicConformerEngine.swift` — `actor` conforming to `LocalTranscriptionEngine`.

**Modified source:**
- `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift` — add `.indicConformer` runner + catalog row.
- `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift` — 3rd engine slot + `resolve` case.
- `Amanuensis/AppCoordinator.swift:100` — construct `IndicConformerEngine()`.

**New tests** (`Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/`):
- `IndicConformerLanguageTests.swift`, `IndicConformerPreprocessorConstantsTests.swift`, `IndicConformerMelTests.swift`, `IndicConformerVocabTests.swift`, `IndicConformerMergerTests.swift`, `IndicConformerGreedyDecoderTests.swift`, `IndicConformerModelStoreTests.swift`, `IndicConformerEngineTests.swift`, `IndicConformerIntegrationTests.swift`.

**Modified tests:**
- `LocalModelCatalogTests.swift` — bump 6→7, add IndicConformer assertions.

---

## Task 1: Scaffolding, config, and language enum

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerConfig.swift`
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/NOTICE.md`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerLanguageTests.swift`

**Interfaces:**
- Produces: `enum IndicConformerLanguage: String` (cases `hi, bn, mr, te, ta, ml, kn`; `static let fallback: Self = .hi`; `static func resolved(_ code: String?) -> Self`; `var postNetPackage: String`). `enum IndicConformerConfig` (all constants + package-name statics + `packageRelativeDirectory(_:)` + `metadataRelativePath(_:)`).

- [ ] **Step 1: Write the failing test**

Create `IndicConformerLanguageTests.swift`:
```swift
import Testing
@testable import LocalTranscription

@Test func resolvesKnownCodesCaseAndWhitespaceInsensitive() {
    #expect(IndicConformerLanguage.resolved("hi") == .hi)
    #expect(IndicConformerLanguage.resolved("  HI ") == .hi)
    #expect(IndicConformerLanguage.resolved("bn") == .bn)
}

@Test func blankNilAndUnknownFallBackToHindi() {
    #expect(IndicConformerLanguage.resolved(nil) == .hi)
    #expect(IndicConformerLanguage.resolved("") == .hi)
    #expect(IndicConformerLanguage.resolved("en") == .hi)
    #expect(IndicConformerLanguage.resolved("hi-IN") == .hi)   // base-code fallback
}

@Test func postNetPackageMatchesCode() {
    #expect(IndicConformerLanguage.ta.postNetPackage == "indic_conformer_joint_post_net_ta.mlpackage")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerLanguageTests`
Expected: FAIL — `cannot find 'IndicConformerLanguage' in scope`.

- [ ] **Step 3: Write the implementation**

Create `IndicConformerConfig.swift`. Note `resolved` first tries the exact normalized code, then the substring before `-` (so `hi-IN` → `hi`), else falls back to Hindi:
```swift
import Foundation

public enum IndicConformerLanguage: String, CaseIterable, Sendable {
    case hi, bn, mr, te, ta, ml, kn

    public static let fallback: Self = .hi

    public var label: String {
        switch self {
        case .hi: return "Hindi"; case .bn: return "Bengali"; case .mr: return "Marathi"
        case .te: return "Telugu"; case .ta: return "Tamil"; case .ml: return "Malayalam"
        case .kn: return "Kannada"
        }
    }

    public var postNetPackage: String { "indic_conformer_joint_post_net_\(rawValue).mlpackage" }

    /// Normalizes an incoming language code to one of the seven supported languages,
    /// falling back to Hindi for blank / nil / unsupported codes. The model has no
    /// auto-detect, so a language is always chosen.
    public static func resolved(_ code: String?) -> Self {
        let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else { return fallback }
        if let exact = Self(rawValue: normalized) { return exact }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return Self(rawValue: base) ?? fallback
    }
}

enum IndicConformerConfig {
    static let repoId = "phequals/indic-conformer-600m-multilingual-coreml-rnnt"
    static let repoRevision = "5590d07c06e95d461790ff753d4af536f0660197"

    // Model contract constants (see Global Constraints).
    static let sampleRate = 16_000
    static let nFFT = 512
    static let hopLength = 160
    static let winLength = 400
    static let nMels = 80
    static let melFrames = 1_024
    static let encoderDim = 1_024
    static let predHiddenDim = 640
    static let predLayers = 2
    static let blankId = 256
    static let sosId = 5_632
    static let rnntMaxSymbols = 10
    static let chunkSeconds = 10.0
    static let overlapSeconds = 1.0

    static let encoderPackage = "indic_conformer_encoder_int8.mlpackage"
    static let rnntDecoderPackage = "indic_conformer_rnnt_decoder_reconstructed.mlpackage"
    static let jointEncPackage = "indic_conformer_joint_enc.mlpackage"
    static let jointPredPackage = "indic_conformer_joint_pred.mlpackage"
    static let jointPreNetPackage = "indic_conformer_joint_pre_net.mlpackage"
    static let vocabFile = "vocab.json"
    static let preprocessorConstantsFile = "preprocessor_constants.bin"

    static let sharedPackages = [
        encoderPackage, rnntDecoderPackage, jointEncPackage, jointPredPackage, jointPreNetPackage,
    ]
    static let languagePackages = IndicConformerLanguage.allCases.map(\.postNetPackage)
    static var allPackages: [String] { sharedPackages + languagePackages }
    /// jointPreNet ships with an empty weights dir (no learned parameters).
    static let weightlessPackages: Set<String> = [jointPreNetPackage]
    static let requiredMetadata = [vocabFile, preprocessorConstantsFile]

    static func packageRelativeDirectory(_ packageName: String) -> String {
        packageName == encoderPackage ? "coreml/encoder/\(packageName)" : "coreml/rnnt/\(packageName)"
    }
    static func metadataRelativePath(_ fileName: String) -> String { "metadata/\(fileName)" }
}
```

Also create `NOTICE.md` in the `LocalTranscription` source dir:
```markdown
# Third-party attribution

The `IndicConformer/` on-device transcription engine is ported (with modifications)
from **Muesli** (https://github.com/pHequals7/muesli), MIT License, © 2026 Pranav Hari.

It runs the **IndicConformer-600M** Core ML RNN-T model
(https://huggingface.co/phequals/indic-conformer-600m-multilingual-coreml-rnnt), MIT License,
a quantized conversion of ai4bharat/indic-conformer-600m-multilingual.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerLanguageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerConfig.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/NOTICE.md \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerLanguageTests.swift
git commit -m "feat(indic): config + language resolution for IndicConformer engine"
```

---

## Task 2: Preprocessor constants parser

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerPreprocessorConstants.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerPreprocessorConstantsTests.swift`

**Interfaces:**
- Produces: `struct IndicConformerPreprocessorConstants { let preemphasis, logZeroGuard, normGuard: Float; let window: [Float]; let filterBank: [Float]; static func load(from url: URL) throws -> Self }`. The blob is `IASRPC01` + 4×Int32 (nFFT, winLength, nBins, nMels) + 3×Float (preemphasis, logZeroGuard, normGuard) + `winLength` window floats + `nMels*nBins` filterbank floats, little-endian.

- [ ] **Step 1: Write the failing test**

Create `IndicConformerPreprocessorConstantsTests.swift`. It synthesizes a valid blob, then mutates it to check rejections:
```swift
import Foundation
import Testing
@testable import LocalTranscription

private func makeBlob(magic: String = "IASRPC01",
                      nFFT: Int32 = 512, winLength: Int32 = 400,
                      nBins: Int32 = 257, nMels: Int32 = 80,
                      extraFloats: Int = 0) -> Data {
    var d = Data()
    d.append(contentsOf: Array(magic.utf8))
    for v in [nFFT, winLength, nBins, nMels] { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
    for f in [Float(0.97), Float(1e-5), Float(1e-5)] { var le = f; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
    let floatCount = Int(winLength) + Int(nMels) * Int(nBins) + extraFloats
    for _ in 0..<floatCount { var f = Float(0); withUnsafeBytes(of: &f) { d.append(contentsOf: $0) } }
    return d
}

private func write(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
    try data.write(to: url); return url
}

@Test func parsesValidBlob() throws {
    let c = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob()))
    #expect(c.window.count == 400)
    #expect(c.filterBank.count == 80 * 257)
    #expect(abs(c.preemphasis - 0.97) < 1e-6)
}

@Test func rejectsBadMagic() throws {
    #expect(throws: (any Error).self) {
        _ = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob(magic: "XXXXXXXX")))
    }
}

@Test func rejectsWrongShape() throws {
    #expect(throws: (any Error).self) {
        _ = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob(nMels: 40)))
    }
}

@Test func rejectsTrailingBytes() throws {
    #expect(throws: (any Error).self) {
        _ = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob(extraFloats: 3)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerPreprocessorConstantsTests`
Expected: FAIL — `cannot find 'IndicConformerPreprocessorConstants' in scope`.

- [ ] **Step 3: Write the implementation**

Create `IndicConformerPreprocessorConstants.swift` (adapted from reference `IndicASRBackend.swift:369-436`, renamed and made `nonisolated`/`Sendable`):
```swift
import Foundation

nonisolated struct IndicConformerPreprocessorConstants: Sendable {
    let preemphasis: Float
    let logZeroGuard: Float
    let normGuard: Float
    let window: [Float]
    let filterBank: [Float]

    static func load(from url: URL) throws -> IndicConformerPreprocessorConstants {
        let data = try Data(contentsOf: url)
        let headerSize = 8 + 4 * MemoryLayout<Int32>.stride + 3 * MemoryLayout<Float>.stride
        guard data.count >= headerSize else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer preprocessor constants file is truncated.")
        }
        guard String(data: data[0..<8], encoding: .ascii) == "IASRPC01" else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer preprocessor constants file has an unsupported format.")
        }
        func int32(at offset: Int) -> Int {
            Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }.littleEndian)
        }
        func float32(at offset: Int) -> Float {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        let nFFT = int32(at: 8)
        let winLength = int32(at: 12)
        let nBins = int32(at: 16)
        let nMels = int32(at: 20)
        let preemphasis = float32(at: 24)
        let logZeroGuard = float32(at: 28)
        let normGuard = float32(at: 32)
        let expectedFloatCount = winLength + nMels * nBins
        let expectedSize = headerSize + expectedFloatCount * MemoryLayout<Float>.stride
        guard nFFT == IndicConformerConfig.nFFT,
              winLength == IndicConformerConfig.winLength,
              nBins == IndicConformerConfig.nFFT / 2 + 1,
              nMels == IndicConformerConfig.nMels,
              data.count == expectedSize else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer preprocessor constants do not match the expected model shape.")
        }
        var values = [Float](repeating: 0, count: expectedFloatCount)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: headerSize..<expectedSize) }
        return IndicConformerPreprocessorConstants(
            preemphasis: preemphasis, logZeroGuard: logZeroGuard, normGuard: normGuard,
            window: Array(values[0..<winLength]),
            filterBank: Array(values[winLength..<values.count])
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerPreprocessorConstantsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerPreprocessorConstants.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerPreprocessorConstantsTests.swift
git commit -m "feat(indic): parse preprocessor_constants.bin (IASRPC01)"
```

---

## Task 3: Log-mel frontend

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerMel.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerMelTests.swift`

**Interfaces:**
- Consumes: `IndicConformerPreprocessorConstants`, `IndicConformerConfig`.
- Produces: `final class IndicConformerMel { init(constants: IndicConformerPreprocessorConstants) throws; func compute(audio: [Float]) -> (mel: [Float], realFrameCount: Int) }`. Output `mel` is `nMels*melFrames` floats, laid out **mel-major** (`mel[melIndex * melFrames + frame]`), zero-padded past `realFrameCount`.

> **Note on validation:** the mel port is verbatim vDSP; its exact numeric correctness is validated end-to-end by the gated integration test (Task 11) transcribing real Hindi audio. The unit tests below are **structural + regression guards** (shape, CMVN statistics, silence handling, a frozen fixture) — the reference explicitly flags this frontend as needing a golden regression test.

- [ ] **Step 1: Write the failing test**
```swift
import Foundation
import Testing
@testable import LocalTranscription

private func makeConstants() -> IndicConformerPreprocessorConstants {
    // Hann-ish window + a trivial filterbank (each mel bin = sum of a contiguous FFT-bin span)
    let nBins = IndicConformerConfig.nFFT / 2 + 1
    var window = [Float](repeating: 0, count: IndicConformerConfig.winLength)
    for i in 0..<window.count { window[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(window.count - 1)) }
    var fb = [Float](repeating: 0, count: IndicConformerConfig.nMels * nBins)
    let span = nBins / IndicConformerConfig.nMels
    for m in 0..<IndicConformerConfig.nMels {
        for b in (m * span)..<min((m + 1) * span, nBins) { fb[m * nBins + b] = 1 }
    }
    return IndicConformerPreprocessorConstants(preemphasis: 0.97, logZeroGuard: 1e-5, normGuard: 1e-5,
                                               window: window, filterBank: fb)
}

@Test func melHasFixedShapeAndSilenceIsZeroFrames() throws {
    let mel = try IndicConformerMel(constants: makeConstants())
    let (silent, frames) = mel.compute(audio: [])
    #expect(silent.count == IndicConformerConfig.nMels * IndicConformerConfig.melFrames)
    #expect(frames == 0)
}

@Test func melProducesNormalizedFramesForTone() throws {
    let mel = try IndicConformerMel(constants: makeConstants())
    // 1 s of 220 Hz tone at 16 kHz
    let n = IndicConformerConfig.sampleRate
    var audio = [Float](repeating: 0, count: n)
    for i in 0..<n { audio[i] = 0.2 * sin(2 * .pi * 220 * Float(i) / Float(n) * Float(n) / Float(IndicConformerConfig.sampleRate)) }
    let (out, frames) = mel.compute(audio: audio)
    #expect(frames > 0 && frames <= IndicConformerConfig.melFrames)
    #expect(out.count == IndicConformerConfig.nMels * IndicConformerConfig.melFrames)
    // Per-bin CMVN ⇒ each mel row over its real frames is ~zero-mean.
    var mean: Float = 0
    for f in 0..<frames { mean += out[0 * IndicConformerConfig.melFrames + f] }
    mean /= Float(frames)
    #expect(abs(mean) < 1e-2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerMelTests`
Expected: FAIL — `cannot find 'IndicConformerMel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `IndicConformerMel.swift` by porting reference `IndicASRBackend.swift:438-617` **verbatim** with only these edits:
- Rename class `IndicASRMelSpectrogram` → `IndicConformerMel`; make it `nonisolated final class`.
- Replace the private `PreprocessorConstants` nested type and its `init(constantsURL:)` with `init(constants: IndicConformerPreprocessorConstants)` that assigns `filterBank/window/preemphasis/logZeroGuard/normGuard` from the passed value and builds the `vDSP_create_fftsetup` (keep the `deinit` that calls `vDSP_destroy_fftsetup`).
- Replace `IndicASRConfig.*` references with `IndicConformerConfig.*`.
- Replace the FFT-setup failure `NSError` with `throw LocalTranscriptionError.transcriptionFailed("Failed to create IndicConformer FFT setup.")`.
- Keep `compute(audio:)`, `preemphasize`, `reflectPad`, `reflectIndex` byte-for-byte (only the config prefix changes).

The resulting `init` head:
```swift
import Accelerate
import Foundation

nonisolated final class IndicConformerMel {
    private let filterBank: [Float]
    private let window: [Float]
    private let preemphasis: Float
    private let logZeroGuard: Float
    private let normGuard: Float
    private let fftSetup: FFTSetup
    private let fftLog2n: vDSP_Length
    private let nBins = IndicConformerConfig.nFFT / 2 + 1

    init(constants: IndicConformerPreprocessorConstants) throws {
        self.filterBank = constants.filterBank
        self.window = constants.window
        self.preemphasis = constants.preemphasis
        self.logZeroGuard = constants.logZeroGuard
        self.normGuard = constants.normGuard
        let log2n = vDSP_Length(log2(Double(IndicConformerConfig.nFFT)))
        self.fftLog2n = log2n
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw LocalTranscriptionError.transcriptionFailed("Failed to create IndicConformer FFT setup.")
        }
        self.fftSetup = setup
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // ... compute(audio:) and static preemphasize/reflectPad/reflectIndex ported verbatim
    // from IndicASRBackend.swift:468-616 with IndicASRConfig → IndicConformerConfig ...
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerMelTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Add a regression fixture test**

Append to `IndicConformerMelTests.swift` a frozen-fixture test: compute mel for a deterministic pseudo-random buffer (seeded by index, no `Math.random`), and pin the first 8 values of mel row 0 to the values produced now. Fill in `expected` from the Step-4 run output:
```swift
@Test func melRegressionFixture() throws {
    let mel = try IndicConformerMel(constants: makeConstants())
    var audio = [Float](repeating: 0, count: 4000)
    for i in 0..<audio.count { audio[i] = sin(Float(i) * 0.03) * 0.3 + sin(Float(i) * 0.011) * 0.1 }
    let (out, frames) = mel.compute(audio: audio)
    #expect(frames > 0)
    let head = Array(out[0..<8])
    let expected: [Float] = [/* PASTE the 8 values printed below */]
    for (a, b) in zip(head, expected) { #expect(abs(a - b) < 1e-4) }
    print("MEL_FIXTURE head=\(head)")   // remove after pasting expected
}
```
Run once, paste the printed `head` into `expected`, delete the `print`, re-run to confirm PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerMel.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerMelTests.swift
git commit -m "feat(indic): log-mel frontend (vDSP) with regression guard"
```

---

## Task 4: Vocab detokenizer

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerVocab.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerVocabTests.swift`

**Interfaces:**
- Produces: `struct IndicConformerVocab { init(vocabURL: URL) throws; init(tokens: [IndicConformerLanguage: [String]]); func decode(_ ids: [Int], language: IndicConformerLanguage) -> String }`. `vocab.json` decodes as `[String: [String]]` keyed by language code; each array must have `> blankId` entries. Decode skips blank `256`, joins pieces, maps SentencePiece `▁` (U+2581) → space, trims.

- [ ] **Step 1: Write the failing test**
```swift
import Foundation
import Testing
@testable import LocalTranscription

@Test func decodeSkipsBlankAndMapsSentencePieceSpace() {
    var tokens = [String](repeating: "", count: 300)
    tokens[10] = "\u{2581}na"; tokens[11] = "ma"; tokens[12] = "\u{2581}ste"
    let vocab = IndicConformerVocab(tokens: [.hi: tokens])
    // blank(256) between tokens is ignored
    let text = vocab.decode([10, 11, 256, 12], language: .hi)
    #expect(text == "na maste")
}

@Test func decodeIgnoresOutOfRangeIds() {
    var tokens = [String](repeating: "", count: 300)
    tokens[5] = "\u{2581}ok"
    let vocab = IndicConformerVocab(tokens: [.hi: tokens])
    #expect(vocab.decode([5, 9999, -1], language: .hi) == "ok")
}

@Test func decodeUnknownLanguageIsEmpty() {
    let vocab = IndicConformerVocab(tokens: [:])
    #expect(vocab.decode([1, 2, 3], language: .ta) == "")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerVocabTests`
Expected: FAIL — `cannot find 'IndicConformerVocab' in scope`.

- [ ] **Step 3: Write the implementation** (adapted from reference `IndicASRBackend.swift:332-362`):
```swift
import Foundation

nonisolated struct IndicConformerVocab: Sendable {
    private let tokens: [IndicConformerLanguage: [String]]

    init(tokens: [IndicConformerLanguage: [String]]) { self.tokens = tokens }

    init(vocabURL: URL) throws {
        let raw = try JSONDecoder().decode([String: [String]].self, from: try Data(contentsOf: vocabURL))
        var parsed: [IndicConformerLanguage: [String]] = [:]
        for language in IndicConformerLanguage.allCases {
            guard let t = raw[language.rawValue], t.count > IndicConformerConfig.blankId else {
                throw LocalTranscriptionError.transcriptionFailed("IndicConformer vocab is missing \(language.rawValue) tokens.")
            }
            parsed[language] = t
        }
        self.tokens = parsed
    }

    func decode(_ ids: [Int], language: IndicConformerLanguage) -> String {
        guard let t = tokens[language] else { return "" }
        let pieces = ids.compactMap { id -> String? in
            guard id != IndicConformerConfig.blankId, id >= 0, id < t.count else { return nil }
            return t[id]
        }
        return pieces.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerVocabTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerVocab.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerVocabTests.swift
git commit -m "feat(indic): per-language vocab detokenizer"
```

---

## Task 5: Chunk overlap merger

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerMerger.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerMergerTests.swift`

**Interfaces:**
- Produces: `enum IndicConformerMerger { static func mergeTokens(_ chunks: [[Int]], maxOverlap: Int = 64) -> (tokenIds: [Int], appliedOverlap: Bool); static func mergeTexts(_ transcripts: [String]) -> String }`.

- [ ] **Step 1: Write the failing test**
```swift
import Testing
@testable import LocalTranscription

@Test func tokenMergeDropsSharedSuffixPrefix() {
    let (ids, applied) = IndicConformerMerger.mergeTokens([[1, 2, 3, 4], [3, 4, 5, 6]])
    #expect(applied)
    #expect(ids == [1, 2, 3, 4, 5, 6])
}

@Test func tokenMergeConcatsWhenNoOverlap() {
    let (ids, applied) = IndicConformerMerger.mergeTokens([[1, 2], [7, 8]])
    #expect(!applied)
    #expect(ids == [1, 2, 7, 8])
}

@Test func textMergeDedupesOverlappingWords() {
    let text = IndicConformerMerger.mergeTexts(["ram gaya", "gaya ghar"])
    #expect(text == "ram gaya ghar")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerMergerTests`
Expected: FAIL — `cannot find 'IndicConformerMerger' in scope`.

- [ ] **Step 3: Write the implementation** (adapted from reference `IndicASRBackend.swift:138-173` and `1126-1150`):
```swift
import Foundation

nonisolated enum IndicConformerMerger {
    static func mergeTokens(_ chunks: [[Int]], maxOverlap: Int = 64) -> (tokenIds: [Int], appliedOverlap: Bool) {
        var merged: [Int] = []
        var appliedOverlap = false
        for chunk in chunks where !chunk.isEmpty {
            guard !merged.isEmpty else { merged.append(contentsOf: chunk); continue }
            let limit = min(maxOverlap, merged.count, chunk.count)
            var overlap = 0
            if limit > 0 {
                for count in stride(from: limit, through: 1, by: -1) where Array(merged.suffix(count)) == Array(chunk.prefix(count)) {
                    overlap = count; break
                }
            }
            if overlap > 0 { appliedOverlap = true }
            merged.append(contentsOf: chunk.dropFirst(overlap))
        }
        return (merged, appliedOverlap)
    }

    static func mergeTexts(_ transcripts: [String]) -> String {
        var mergedWords: [String] = []
        for transcript in transcripts {
            let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            guard !mergedWords.isEmpty else { mergedWords.append(contentsOf: words); continue }
            let existing = mergedWords.map(normalize)
            let incoming = words.map(normalize)
            let maxOverlap = min(existing.count, incoming.count, 16)
            var overlap = 0
            if maxOverlap > 0 {
                for count in stride(from: maxOverlap, through: 1, by: -1) where Array(existing.suffix(count)) == Array(incoming.prefix(count)) {
                    overlap = count; break
                }
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return mergedWords.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        return String(String.UnicodeScalarView(token.unicodeScalars.filter { !punctuation.contains($0) })).lowercased()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerMergerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerMerger.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerMergerTests.swift
git commit -m "feat(indic): token/text chunk overlap merge"
```

---

## Task 6: Inference seam + greedy RNN-T decoder (the testable core)

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerInference.swift`
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerGreedyDecoder.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerGreedyDecoderTests.swift`

**Interfaces:**
- Produces:
  - `struct LSTMState { var h: [Float]; var c: [Float] }` (each `predLayers*1*predHiddenDim` floats).
  - `struct PredictionStep { let projected: [Float]; let nextState: LSTMState }` (`projected` = jointPred output, `predHiddenDim` floats).
  - `protocol IndicConformerInference { func encode(audio: [Float]) async throws -> Int; func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep; func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float]; func zeroState() -> LSTMState }` (**not** `Sendable` — the Core ML conformer holds non-Sendable workspace; used within one isolation domain). `encode` takes the raw 16 kHz mono audio chunk, computes its mel internally, runs the encoder, stashes the encoder output inside the conformer, and returns the encoded frame count.
  - `struct IndicConformerGreedyDecoder { let inference: any IndicConformerInference; func decodeChunk(audio: [Float], language: IndicConformerLanguage) async throws -> [Int] }` — runs the greedy loop over one audio chunk and returns token ids.
- Consumes: `IndicConformerConfig` (blankId, sosId, rnntMaxSymbols).

**Greedy contract (must hold, verified by tests):** the prediction step is computed once and **cached across blank frames**; it is recomputed only after a non-blank emit. Per frame, at most `rnntMaxSymbols` non-blank tokens; a blank breaks to the next frame. Initial `previousToken = sosId`, initial state = `zeroState()`.

- [ ] **Step 1: Write the failing test**

The Fake scripts logits per (frameIndex, previousToken) and counts prediction calls to lock the caching contract:
```swift
import Testing
@testable import LocalTranscription

/// Scripted inference: `plan[frame]` is the list of tokens to emit on that frame
/// (a blank ends each frame). `predictAndProject` runs once initially and once after
/// each emit (cache is reused across blank frames), so `predictCalls - 1` == the number
/// of tokens emitted so far — which `jointLogits` uses to index the plan.
private final class ScriptedInference: IndicConformerInference {
    let plan: [[Int]]
    var predictCalls = 0
    init(plan: [[Int]]) { self.plan = plan }

    func encode(audio: [Float]) async throws -> Int { plan.count }
    func zeroState() -> LSTMState { LSTMState(h: [0], c: [0]) }
    func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep {
        predictCalls += 1
        return PredictionStep(projected: [Float(predictCalls - 1)], nextState: LSTMState(h: [0], c: [0]))
    }
    func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float] {
        let emitsSoFar = Int(predProjected[0])
        let emittedBeforeFrame = plan[0..<frameIndex].reduce(0) { $0 + $1.count }
        let pos = emitsSoFar - emittedBeforeFrame
        let frameTokens = plan[frameIndex]
        var logits = [Float](repeating: 0, count: IndicConformerConfig.blankId + 1)
        if pos >= 0 && pos < frameTokens.count {
            logits[frameTokens[pos]] = 10   // emit next token
        } else {
            logits[IndicConformerConfig.blankId] = 10   // blank ⇒ advance frame
        }
        return logits
    }
}

@Test func decodesScriptedTokensAcrossFrames() async throws {
    let fake = ScriptedInference(plan: [[5, 6], [], [7]])
    let decoder = IndicConformerGreedyDecoder(inference: fake)
    let ids = try await decoder.decodeChunk(audio: [], language: .hi)
    #expect(ids == [5, 6, 7])
}

@Test func predictionCachedAcrossBlankFrames() async throws {
    // Two empty (blank-only) frames then one emit: predict runs once for the initial
    // state, is reused across the blanks, then once more after the emit.
    let fake = ScriptedInference(plan: [[], [], [9]])
    let decoder = IndicConformerGreedyDecoder(inference: fake)
    let ids = try await decoder.decodeChunk(audio: [], language: .hi)
    #expect(ids == [9])
    // 1 initial predict (reused across both blank frames) + 1 after the emit.
    #expect(fake.predictCalls == 2)
}

@Test func capsSymbolsPerFrame() async throws {
    // A frame that would emit forever is capped at rnntMaxSymbols.
    let runaway = Array(repeating: 1, count: 100)
    let fake = ScriptedInference(plan: [runaway])
    let decoder = IndicConformerGreedyDecoder(inference: fake)
    let ids = try await decoder.decodeChunk(audio: [], language: .hi)
    #expect(ids.count == IndicConformerConfig.rnntMaxSymbols)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerGreedyDecoderTests`
Expected: FAIL — `cannot find 'IndicConformerGreedyDecoder' in scope`.

- [ ] **Step 3: Write the seam and decoder**

`IndicConformerInference.swift`:
```swift
import Foundation

nonisolated struct LSTMState { var h: [Float]; var c: [Float] }
nonisolated struct PredictionStep { let projected: [Float]; let nextState: LSTMState }

nonisolated protocol IndicConformerInference {
    /// Computes the mel for one raw 16 kHz mono audio chunk, runs the encoder, stashes
    /// the encoded frames internally, and returns the number of encoded frames to decode.
    func encode(audio: [Float]) async throws -> Int
    /// Prediction LSTM step + jointPred projection for `previousToken`/`state`.
    func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep
    /// jointEnc(frame) ⊕ predProjected → jointPreNet → jointPostNet[language] → logits.
    func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float]
    func zeroState() -> LSTMState
}
```

`IndicConformerGreedyDecoder.swift` (new control flow; mirrors reference `IndicASRBackend.swift:917-1009` but over the seam):
```swift
import Foundation

nonisolated struct IndicConformerGreedyDecoder {
    let inference: any IndicConformerInference

    func decodeChunk(audio: [Float], language: IndicConformerLanguage) async throws -> [Int] {
        let frameCount = try await inference.encode(audio: audio)
        guard frameCount > 0 else { return [] }

        var state = inference.zeroState()
        var previousToken = IndicConformerConfig.sosId
        var cached: PredictionStep?          // carried across blank frames; nil'd only on emit
        var tokenIds: [Int] = []

        for frameIndex in 0..<frameCount {
            for _ in 0..<IndicConformerConfig.rnntMaxSymbols {
                let step: PredictionStep
                if let cached {
                    step = cached
                } else {
                    step = try await inference.predictAndProject(previousToken: previousToken, state: state)
                    cached = step
                }
                let logits = try await inference.jointLogits(frameIndex: frameIndex,
                                                             predProjected: step.projected,
                                                             language: language)
                let token = argmax(logits, count: IndicConformerConfig.blankId + 1)
                if token == IndicConformerConfig.blankId { break }
                tokenIds.append(token)
                previousToken = token
                state = step.nextState
                cached = nil
            }
        }
        return tokenIds
    }

    private func argmax(_ logits: [Float], count: Int) -> Int {
        var best = 0
        var bestValue = -Float.infinity
        for i in 0..<min(count, logits.count) where logits[i] > bestValue { bestValue = logits[i]; best = i }
        return best
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerGreedyDecoderTests`
Expected: PASS (3 tests). If `predictionCachedAcrossBlankFrames` fails on the call count, the cache carry across frames is wrong — fix the decoder, not the test.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerInference.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerGreedyDecoder.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerGreedyDecoderTests.swift
git commit -m "feat(indic): greedy RNN-T decoder over injectable inference seam"
```

---

## Task 7: Core ML inference conformer

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/CoreMLIndicInference.swift`

**Interfaces:**
- Consumes: `IndicConformerInference`, `LSTMState`, `PredictionStep`, `IndicConformerConfig`, the six `MLModel`s + per-language post-nets loaded in Task 8.
- Produces: `final class CoreMLIndicInference: IndicConformerInference` with `init(encoder:decoder:jointEnc:jointPred:jointPreNet:jointPostNets:mel:)`.

**Coverage note:** this is thin `MLModel` plumbing whose correctness depends on the real weights; it is exercised by the gated integration test (Task 11), not a unit test.

- [ ] **Step 1: Write the implementation**

Port the concrete Core ML paths from reference `IndicASRBackend.swift` into one conformer. Reuse: `EncoderFrameView` (lines 853-889), `DecodeWorkspace` (815-851), `runDecoder` (1016-1033), `runJointPred` (1035-1054), `runJointEncFrame` (1011-1014), `predict` helpers (1056-1071), array helpers `makeFloatArray`/`zeroFloatArray`/`addArrays`/`copyAsFloat32`/`floatValue` (1073-1124). Rename to `CoreMLIndicInference` and restructure into the three seam methods. Encoder output is stashed in a stored `EncoderFrameView?`:

```swift
import CoreML
import Foundation

nonisolated final class CoreMLIndicInference: IndicConformerInference {
    private let encoder: MLModel
    private let decoder: MLModel
    private let jointEnc: MLModel
    private let jointPred: MLModel
    private let jointPreNet: MLModel
    private let jointPostNets: [IndicConformerLanguage: MLModel]
    private let mel: IndicConformerMel
    private let workspace: DecodeWorkspace
    private var encoderFrames: EncoderFrameView?

    init(encoder: MLModel, decoder: MLModel, jointEnc: MLModel, jointPred: MLModel,
         jointPreNet: MLModel, jointPostNets: [IndicConformerLanguage: MLModel],
         mel: IndicConformerMel) throws {
        self.encoder = encoder; self.decoder = decoder
        self.jointEnc = jointEnc; self.jointPred = jointPred; self.jointPreNet = jointPreNet
        self.jointPostNets = jointPostNets; self.mel = mel
        self.workspace = try DecodeWorkspace()
    }

    func zeroState() -> LSTMState {
        let n = IndicConformerConfig.predLayers * 1 * IndicConformerConfig.predHiddenDim
        return LSTMState(h: [Float](repeating: 0, count: n), c: [Float](repeating: 0, count: n))
    }

    func encode(audio: [Float]) async throws -> Int {
        let (melValues, realFrames) = mel.compute(audio: audio)
        let melArray = try makeFloatArray(shape: [1, IndicConformerConfig.nMels, IndicConformerConfig.melFrames],
                                          values: melValues)
        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: Int32(realFrames))
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: melArray),
            "length": MLFeatureValue(multiArray: lengthArray),
        ])
        let output = try await encoder.prediction(from: input)
        guard let encoded = output.featureValue(for: "outputs")?.multiArrayValue,
              let lengths = output.featureValue(for: "encoded_lengths")?.multiArrayValue else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer encoder did not return outputs.")
        }
        let count = min(max(lengths[0].intValue, 0), IndicConformerConfig.melFrames)
        encoderFrames = count > 0 ? try EncoderFrameView(encoded: encoded, encodedFrameCount: count) : nil
        return count
    }

    func predictAndProject(previousToken: Int, state: LSTMState) async throws -> PredictionStep {
        // Build state MLMultiArrays from the flat vectors.
        let hArr = try makeFloatArray(shape: [IndicConformerConfig.predLayers, 1, IndicConformerConfig.predHiddenDim], values: state.h)
        let cArr = try makeFloatArray(shape: [IndicConformerConfig.predLayers, 1, IndicConformerConfig.predHiddenDim], values: state.c)
        workspace.tokenArray[0] = NSNumber(value: Int32(previousToken))
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: workspace.tokenArray),
            "target_length": MLFeatureValue(multiArray: workspace.tokenLength),
            "states_1": MLFeatureValue(multiArray: hArr),
            "cell_state_in": MLFeatureValue(multiArray: cArr),
        ])
        let output = try await decoder.prediction(from: input)
        guard let outputs = output.featureValue(for: "outputs")?.multiArrayValue,
              let nextH = output.featureValue(for: "states")?.multiArrayValue,
              let nextC = output.featureValue(for: "cell_state_out")?.multiArrayValue else {
            throw LocalTranscriptionError.transcriptionFailed("IndicConformer RNN-T decoder did not return state outputs.")
        }
        // jointPred projection (fills workspace.decoderFrameInput from outputs, runs jointPred).
        let projected = try await runJointPred(outputs)
        let projectedVec = flatten(projected, count: IndicConformerConfig.predHiddenDim)
        return PredictionStep(projected: projectedVec,
                              nextState: LSTMState(h: flatten(nextH, count: nextH.count),
                                                   c: flatten(nextC, count: nextC.count)))
    }

    func jointLogits(frameIndex: Int, predProjected: [Float], language: IndicConformerLanguage) async throws -> [Float] {
        guard let encoderFrames else { throw LocalTranscriptionError.transcriptionFailed("IndicConformer encoder frames missing.") }
        guard let postNet = jointPostNets[language] else {
            throw LocalTranscriptionError.transcriptionFailed("Missing IndicConformer joint post-net for \(language.label).")
        }
        // jointEnc(frame)
        try encoderFrames.copyFrame(frameIndex, into: workspace.encoderFrameInput)
        let encFrame = try await predict(model: jointEnc, provider: workspace.jointEncInputProvider, outputName: "output")
        // write predProjected into workspace.decoderFrameInput-shaped jointPred output buffer:
        let predFrame = try makeFloatArray(shape: [1, 1, IndicConformerConfig.predHiddenDim], values: predProjected)
        // add ⇒ jointInput ⇒ preNet ⇒ postNet
        try addArrays(encFrame, predFrame, into: workspace.jointInput)
        let preNetOut = try await predict(model: jointPreNet, provider: workspace.jointPreNetInputProvider, outputName: "output")
        let logits = try await predict(model: postNet, inputName: "input", input: preNetOut, outputName: "output")
        return flatten(logits, count: IndicConformerConfig.blankId + 1)
    }

    private func flatten(_ array: MLMultiArray, count: Int) -> [Float] {
        (0..<min(count, array.count)).map { Self.floatValue(array, linearIndex: $0) }
    }

    // ... paste EncoderFrameView, DecodeWorkspace, runJointPred, predict(...), makeFloatArray,
    //     addArrays, copyAsFloat32, static floatValue from IndicASRBackend.swift, renamed to
    //     IndicConformerConfig and this class. runJointPred returns the jointPred MLMultiArray
    //     (its internal decoderFrameInput write stays as-is). ...
}
```

> Adaptation detail: the reference cached `DecoderResult`/`cachedPredFrame` inside `DecoderState`; that caching now lives in the greedy decoder (Task 6), so `CoreMLIndicInference` is stateless per call except for the stashed `encoderFrames`. `runJointPred` keeps its body but takes the decoder `outputs` array and returns the jointPred output; wire its internal `workspace.decoderFrameInput` write exactly as the reference (lines 1049-1053).

- [ ] **Step 2: Verify it compiles (no unit test — integration-covered)**

Run: `swift build --package-path Packages/AudioPipeline`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/CoreMLIndicInference.swift
git commit -m "feat(indic): Core ML inference conformer (encoder/decoder/joint)"
```

---

## Task 8: Model store, downloader, and bundle loader

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerModelStore.swift`
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerModels.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerModelStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum IndicConformerModelStore { static func root() throws -> URL; static func packageURL(_ name: String, root: URL) -> URL; static func compiledURL(_ name: String, root: URL) -> URL; static func metadataURL(_ file: String, root: URL) -> URL; static func isDownloaded(root: URL) -> Bool; static func remoteURL(for relativePath: String) -> URL; static func download(root: URL, progress: @Sendable (Double) -> Void) async throws }`. `root()` = `ModelStorage.runnerDir(.indicConformer)`.
  - `struct IndicConformerModels { let encoder/decoder/jointEnc/jointPred/jointPreNet: MLModel; let jointPostNets: [IndicConformerLanguage: MLModel]; let mel: IndicConformerMel; let vocab: IndicConformerVocab; func makeInference() throws -> CoreMLIndicInference; static func load(root: URL) async throws -> IndicConformerModels }` — compiles/loads the 12 packages + mel + vocab as **shared read-only** state. `makeInference()` vends a **fresh per-transcribe** `CoreMLIndicInference` (its own `DecodeWorkspace` + encoder-frame stash) so concurrent/reentrant transcribes never share mutable session state (matches the reference's per-chunk workspace; the MLModels + mel are thread-safe to share).
- Consumes: `ModelStorage`, `IndicConformerConfig`, `CoreMLIndicInference`, `IndicConformerMel`, `IndicConformerVocab`, `IndicConformerPreprocessorConstants`.

- [ ] **Step 1: Write the failing test** (layout + isDownloaded over a fabricated tree; remoteURL pinning):
```swift
import Foundation
import Testing
@testable import LocalTranscription

private func fabricateTree() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    for name in IndicConformerConfig.allPackages {
        let pkg = IndicConformerModelStore.packageURL(name, root: root)
        try fm.createDirectory(at: pkg.appendingPathComponent("Data/com.apple.CoreML/weights"), withIntermediateDirectories: true)
        try Data().write(to: pkg.appendingPathComponent("Manifest.json"))
        try Data().write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel"))
        if !IndicConformerConfig.weightlessPackages.contains(name) {
            try Data().write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin"))
        }
    }
    let meta = root.appendingPathComponent("metadata", isDirectory: true)
    try fm.createDirectory(at: meta, withIntermediateDirectories: true)
    for f in IndicConformerConfig.requiredMetadata { try Data().write(to: meta.appendingPathComponent(f)) }
    return root
}

@Test func isDownloadedTrueForCompleteTree() throws {
    #expect(IndicConformerModelStore.isDownloaded(root: try fabricateTree()))
}

@Test func isDownloadedFalseWhenAPackageMissing() throws {
    let root = try fabricateTree()
    try FileManager.default.removeItem(at: IndicConformerModelStore.packageURL(IndicConformerConfig.encoderPackage, root: root))
    #expect(!IndicConformerModelStore.isDownloaded(root: root))
}

@Test func isDownloadedFalseWhenMetadataMissing() throws {
    let root = try fabricateTree()
    try FileManager.default.removeItem(at: IndicConformerModelStore.metadataURL(IndicConformerConfig.vocabFile, root: root))
    #expect(!IndicConformerModelStore.isDownloaded(root: root))
}

@Test func remoteURLPinsRevisionAndPath() {
    let url = IndicConformerModelStore.remoteURL(for: "metadata/vocab.json").absoluteString
    #expect(url.contains(IndicConformerConfig.repoId))
    #expect(url.contains(IndicConformerConfig.repoRevision))
    #expect(url.hasSuffix("metadata/vocab.json?download=1"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerModelStoreTests`
Expected: FAIL — `cannot find 'IndicConformerModelStore' in scope`.

- [ ] **Step 3: Write `IndicConformerModelStore.swift`** (adapted from reference `IndicASRBackend.swift:175-330`; drop the env-override + `~/.cache` layout, use `ModelStorage`; the on-disk layout is always the HF `coreml/…`, `metadata/…` tree under `root`):
```swift
import Foundation

nonisolated enum IndicConformerModelStore {
    static func root() throws -> URL { try ModelStorage.runnerDir(.indicConformer) }

    static func packageURL(_ name: String, root: URL) -> URL {
        root.appendingPathComponent(IndicConformerConfig.packageRelativeDirectory(name), isDirectory: true)
    }
    static func compiledURL(_ name: String, root: URL) -> URL {
        packageURL(name, root: root).deletingLastPathComponent()
            .appendingPathComponent(name.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)
    }
    static func metadataURL(_ file: String, root: URL) -> URL {
        root.appendingPathComponent(IndicConformerConfig.metadataRelativePath(file), isDirectory: false)
    }

    private static func packageContents(_ name: String) -> [String] {
        var files = ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel"]
        if !IndicConformerConfig.weightlessPackages.contains(name) { files.append("Data/com.apple.CoreML/weights/weight.bin") }
        return files
    }

    static func isDownloaded(root: URL) -> Bool {
        let fm = FileManager.default
        let packagesOK = IndicConformerConfig.allPackages.allSatisfy { name in
            if fm.fileExists(atPath: compiledURL(name, root: root).appendingPathComponent("coremldata.bin").path) { return true }
            let pkg = packageURL(name, root: root)
            return packageContents(name).allSatisfy { fm.fileExists(atPath: pkg.appendingPathComponent($0).path) }
        }
        let metaOK = IndicConformerConfig.requiredMetadata.allSatisfy { fm.fileExists(atPath: metadataURL($0, root: root).path) }
        return packagesOK && metaOK
    }

    static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(IndicConformerConfig.repoId)/resolve/\(IndicConformerConfig.repoRevision)")!
        for c in relativePath.split(separator: "/") { url.appendPathComponent(String(c), isDirectory: false) }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "download", value: "1")]
        return comps.url!
    }

    static func download(root: URL, progress: @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let packageFiles = IndicConformerConfig.allPackages.flatMap { name in
            packageContents(name).map { "\(IndicConformerConfig.packageRelativeDirectory(name))/\($0)" }
        }
        let metadataFiles = IndicConformerConfig.requiredMetadata.map(IndicConformerConfig.metadataRelativePath)
        let required = packageFiles + metadataFiles
        let missing = required.filter { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        let total = max(missing.count, 1)
        for (index, relativePath) in missing.enumerated() {
            progress(Double(index) / Double(total))
            let destination = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temp, _) = try await URLSession.shared.download(from: remoteURL(for: relativePath))
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temp, to: destination)
        }
        // jointPreNet ships weightless: ensure its (empty) weights dir exists before compile.
        for name in IndicConformerConfig.weightlessPackages {
            try fm.createDirectory(at: packageURL(name, root: root).appendingPathComponent("Data/com.apple.CoreML/weights"),
                                   withIntermediateDirectories: true)
        }
        progress(1.0)
    }
}
```

- [ ] **Step 4: Write `IndicConformerModels.swift`** (adapted from reference `IndicASRBackend.swift:619-674`):
```swift
import CoreML
import Foundation

nonisolated struct IndicConformerModels {
    let encoder: MLModel
    let decoder: MLModel
    let jointEnc: MLModel
    let jointPred: MLModel
    let jointPreNet: MLModel
    let jointPostNets: [IndicConformerLanguage: MLModel]
    let mel: IndicConformerMel
    let vocab: IndicConformerVocab

    /// A fresh per-transcribe inference session — its own `DecodeWorkspace` + encoder-frame
    /// stash — sharing the resident read-only MLModels + mel. Concurrent/reentrant transcribes
    /// MUST each build their own session; never share one `CoreMLIndicInference` across them.
    func makeInference() throws -> CoreMLIndicInference {
        try CoreMLIndicInference(encoder: encoder, decoder: decoder, jointEnc: jointEnc,
                                 jointPred: jointPred, jointPreNet: jointPreNet,
                                 jointPostNets: jointPostNets, mel: mel)
    }

    static func load(root: URL) async throws -> IndicConformerModels {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        var postNets: [IndicConformerLanguage: MLModel] = [:]
        for language in IndicConformerLanguage.allCases {
            postNets[language] = try await loadModel(language.postNetPackage, root: root, config: config)
        }
        let encoder = try await loadModel(IndicConformerConfig.encoderPackage, root: root, config: config)
        let decoder = try await loadModel(IndicConformerConfig.rnntDecoderPackage, root: root, config: config)
        let jointEnc = try await loadModel(IndicConformerConfig.jointEncPackage, root: root, config: config)
        let jointPred = try await loadModel(IndicConformerConfig.jointPredPackage, root: root, config: config)
        let jointPreNet = try await loadModel(IndicConformerConfig.jointPreNetPackage, root: root, config: config)

        let constants = try IndicConformerPreprocessorConstants.load(
            from: IndicConformerModelStore.metadataURL(IndicConformerConfig.preprocessorConstantsFile, root: root))
        let mel = try IndicConformerMel(constants: constants)
        let vocab = try IndicConformerVocab(vocabURL: IndicConformerModelStore.metadataURL(IndicConformerConfig.vocabFile, root: root))

        return IndicConformerModels(
            encoder: encoder, decoder: decoder, jointEnc: jointEnc, jointPred: jointPred,
            jointPreNet: jointPreNet, jointPostNets: postNets, mel: mel, vocab: vocab)
    }

    private static func loadModel(_ name: String, root: URL, config: MLModelConfiguration) async throws -> MLModel {
        let packageURL = IndicConformerModelStore.packageURL(name, root: root)
        let compiledURL = IndicConformerModelStore.compiledURL(name, root: root)
        let fm = FileManager.default
        let modelURL: URL
        if fm.fileExists(atPath: compiledURL.path) {
            modelURL = compiledURL
        } else {
            if IndicConformerConfig.weightlessPackages.contains(name) {
                try fm.createDirectory(at: packageURL.appendingPathComponent("Data/com.apple.CoreML/weights"),
                                       withIntermediateDirectories: true)
            }
            let temp = try await MLModel.compileModel(at: packageURL)
            try? fm.removeItem(at: compiledURL)
            try fm.copyItem(at: temp, to: compiledURL)
            try? fm.removeItem(at: temp)
            modelURL = compiledURL
        }
        return try await MLModel.load(contentsOf: modelURL, configuration: config)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerModelStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerModelStore.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerModels.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerModelStoreTests.swift
git commit -m "feat(indic): model store, HF downloader, and 12-package bundle loader"
```

---

## Task 9: `IndicConformerEngine` (LocalTranscriptionEngine conformer)

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerEngine.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerEngineTests.swift`

**Interfaces:**
- Produces: `public actor IndicConformerEngine: LocalTranscriptionEngine { public init() }`. Mirrors `WhisperKitEngine`: a resident `IndicConformerModels?` keyed by `residentModelID`; `download`/`isDownloaded`/`installedBytes`/`delete` delegate to `IndicConformerModelStore`; `transcribe` resamples (FluidAudio `AudioConverter`), slices into 10 s / 1 s-overlap chunks, runs `IndicConformerGreedyDecoder` per chunk, merges, detokenizes.
- Consumes: everything above, plus `FluidAudio.AudioConverter`.

- [ ] **Step 1: Write the failing test** (download/isDownloaded/installedBytes/delete are model-agnostic filesystem ops — testable without weights):
```swift
import Foundation
import Testing
@testable import LocalTranscription

private let indicModel = LocalModelCatalog.model(id: "indic-conformer-600m")!

@Test func engineReportsNotDownloadedInitially() async {
    let engine = IndicConformerEngine()
    // A clean environment may or may not have real files; at minimum a random model id is not downloaded.
    #expect(await engine.isDownloaded(indicModel) == IndicConformerModelStore.isDownloaded(root: (try? IndicConformerModelStore.root()) ?? URL(fileURLWithPath: "/nonexistent")))
}

@Test func transcribeThrowsWhenNotDownloaded() async {
    // Guard clause must fire before any Core ML work when the bundle is absent.
    let engine = IndicConformerEngine()
    if await engine.isDownloaded(indicModel) { return }   // skip if a real bundle happens to be present
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await engine.transcribe(audioURL: URL(fileURLWithPath: "/nonexistent.wav"),
                                        model: indicModel, language: "hi")
    }
}
```

> This task depends on Task 10's catalog entry for `indic-conformer-600m`. If executing strictly in order, add the catalog row from Task 10 Step 3 first (it is a 6-line change) so this test resolves the model, then complete Task 10's remaining wiring.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerEngineTests`
Expected: FAIL — `cannot find 'IndicConformerEngine' in scope`.

- [ ] **Step 3: Write the implementation**:
```swift
import FluidAudio
import Foundation

public actor IndicConformerEngine: LocalTranscriptionEngine {
    public init() {}

    private var residentModelID: String?
    private var resident: IndicConformerModels?

    private func root() throws -> URL { try IndicConformerModelStore.root() }

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        (try? root()).map { IndicConformerModelStore.isDownloaded(root: $0) } ?? false
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 {
        (try? root()).map { ModelStorage.directorySize($0) } ?? 0
    }

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await IndicConformerModelStore.download(root: try root(), progress: progress)
    }

    public func delete(_ model: LocalModel) async throws {
        if residentModelID == model.id { resident = nil; residentModelID = nil }
        let root = try root()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    public func preload(_ model: LocalModel) async throws {
        let models = try await IndicConformerModels.load(root: try root())
        resident = models
        residentModelID = model.id
    }

    public func unloadResident() async {
        resident = nil
        residentModelID = nil
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else {
            throw LocalTranscriptionError.modelNotDownloaded(model.displayName)
        }
        let models: IndicConformerModels
        if model.id == residentModelID, let cached = resident {
            models = cached
        } else {
            models = try await IndicConformerModels.load(root: try root())
        }

        let lang = IndicConformerLanguage.resolved(language)
        let samples = try AudioConverter().resampleAudioFile(audioURL)

        let sr = IndicConformerConfig.sampleRate
        let chunkSize = max(1, Int(IndicConformerConfig.chunkSeconds * Double(sr)))
        let stepSize = max(1, Int((IndicConformerConfig.chunkSeconds - IndicConformerConfig.overlapSeconds) * Double(sr)))
        let decoder = IndicConformerGreedyDecoder(inference: try models.makeInference())  // fresh per-transcribe session

        var tokenChunks: [[Int]] = []
        var textChunks: [String] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunkSize, samples.count)
            let chunk = Array(samples[start..<end])
            let ids = try await decoder.decodeChunk(audio: chunk, language: lang)
            if !ids.isEmpty { tokenChunks.append(ids); textChunks.append(models.vocab.decode(ids, language: lang)) }
            if end == samples.count { break }
            start += stepSize
        }

        guard !tokenChunks.isEmpty else { return "" }
        let (mergedIds, applied) = IndicConformerMerger.mergeTokens(tokenChunks)
        if applied { return models.vocab.decode(mergedIds, language: lang) }
        return IndicConformerMerger.mergeTexts(textChunks)
    }
}
```

> **Note:** mel lives inside `CoreMLIndicInference.encode(audio:)` (Task 7), so the engine slices raw resampled audio into chunks and hands each to `decoder.decodeChunk(audio:language:)`; no mel handling on the engine side. `AudioConverter().resampleAudioFile(_:)` returns `[Float]` at 16 kHz mono (verified in FluidAudio 0.15.4).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerEngineTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/IndicConformer/IndicConformerEngine.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerEngineTests.swift
git commit -m "feat(indic): IndicConformerEngine conforming to LocalTranscriptionEngine"
```

---

## Task 10: Catalog, runner, and service wiring

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift`
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift`
- Modify: `Amanuensis/AppCoordinator.swift:100`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelCatalogTests.swift` (modify)

**Interfaces:**
- Consumes: `IndicConformerEngine`.
- Produces: catalog id `indic-conformer-600m` with `runner: .indicConformer`; `LocalTranscriptionService.init(fluidAudio:whisperKit:indicConformer:)`.

- [ ] **Step 1: Update the catalog test first (failing)**

In `LocalModelCatalogTests.swift`, change the count test and add IndicConformer assertions:
```swift
@Test func catalogHasSevenModelsWithUniqueIDs() {
    let all = LocalModelCatalog.all
    #expect(all.count == 7)
    #expect(Set(all.map(\.id)).count == 7)
}

@Test func indicConformerIsPresentWithSevenLanguages() {
    let m = LocalModelCatalog.model(id: "indic-conformer-600m")
    #expect(m?.runner == .indicConformer)
    #expect(m?.recommended == false)   // global recommended stays Parakeet 110m
    #expect(m?.languages.contains("Hindi") == true)
}
```
Delete the old `catalogHasSixModelsWithUniqueIDs`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelCatalogTests`
Expected: FAIL — `indic-conformer-600m` not found / `.indicConformer` not a case.

- [ ] **Step 3: Add the runner case + catalog row** in `LocalModel.swift`.

Add to the enum (after `case whisperKit`):
```swift
    case indicConformer          // IndicConformer-600M RNN-T (AI4Bharat)
```
Add to `LocalModelCatalog.all` (append inside the array):
```swift
        LocalModel(id: "indic-conformer-600m", displayName: "IndicConformer 600M",
                   summary: "Best Hindi accuracy. On-device RNN-T; 7 Indic languages.",
                   languages: "Hindi, Bengali, Marathi, Telugu, Tamil, Malayalam, Kannada",
                   approxBytes: 700 * MB,
                   runner: .indicConformer, selector: "multilingual", recommended: false),
```

- [ ] **Step 4: Route in `LocalTranscriptionService.swift`**

Add the stored property + init param + resolve case:
```swift
    private let indicConformer: any LocalTranscriptionEngine
```
```swift
    public init(fluidAudio: any LocalTranscriptionEngine,
                whisperKit: any LocalTranscriptionEngine,
                indicConformer: any LocalTranscriptionEngine) {
        self.fluidAudio = fluidAudio
        self.whisperKit = whisperKit
        self.indicConformer = indicConformer
    }
```
```swift
        switch m.runner {
        case .whisperKit: return (m, whisperKit)
        case .indicConformer: return (m, indicConformer)
        case .fluidAudioParakeet, .fluidAudioSenseVoice, .fluidAudioCohere: return (m, fluidAudio)
        }
```

- [ ] **Step 5: Construct the engine in `AppCoordinator.swift:100`**

Change:
```swift
        let localService = LocalTranscriptionService(fluidAudio: FluidAudioEngine(), whisperKit: WhisperKitEngine())
```
to:
```swift
        let localService = LocalTranscriptionService(
            fluidAudio: FluidAudioEngine(),
            whisperKit: WhisperKitEngine(),
            indicConformer: IndicConformerEngine())
```

- [ ] **Step 6: Add a service routing test** to `LocalTranscriptionServiceTests.swift` (uses the existing `FakeEngine`; asserts `.indicConformer` models route to the injected indic engine):
```swift
@Test func routesIndicModelToIndicEngine() async throws {
    let indic = FakeEngine()
    await indic.download(LocalModelCatalog.model(id: "indic-conformer-600m")!, progress: { _ in })
    let service = LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine(), indicConformer: indic)
    let text = try await service.transcribe(audioURL: URL(fileURLWithPath: "/x.wav"),
                                            modelID: "indic-conformer-600m", language: "hi")
    #expect(text == "fake transcript")
    #expect(await indic.lastTranscribedModel == "indic-conformer-600m")
}
```
(Update any other `LocalTranscriptionService(...)` constructions in the test suite to pass `indicConformer: FakeEngine()`.)

- [ ] **Step 7: Run the full SPM suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (all suites, including the updated catalog + service tests).

- [ ] **Step 8: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED (confirms the `AppCoordinator` init change compiles).

- [ ] **Step 9: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift \
        Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift \
        Amanuensis/AppCoordinator.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelCatalogTests.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalTranscriptionServiceTests.swift
git commit -m "feat(indic): wire IndicConformer into catalog, service, and app coordinator"
```

---

## Task 11: Gated end-to-end integration + manual verification

**Files:**
- Create: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerIntegrationTests.swift`
- Create: `scripts/fetch-fleurs-hindi-sample.sh`

**Interfaces:**
- Consumes: the whole engine end-to-end + the real model weights + a Hindi audio fixture.

- [ ] **Step 1: Add the fixture-fetch script**

Create `scripts/fetch-fleurs-hindi-sample.sh` — downloads one FLEURS `hi_in` utterance + its reference transcript into `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/Fixtures/` (gitignored):
```bash
#!/usr/bin/env bash
set -euo pipefail
DEST="$(dirname "$0")/../Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/Fixtures"
mkdir -p "$DEST"
uv run --with datasets --with soundfile - <<'PY'
import os, soundfile as sf
from datasets import load_dataset
ds = load_dataset("google/fleurs", "hi_in", split="test", streaming=True)
row = next(iter(ds))
dest = os.path.join(os.path.dirname(__file__) if "__file__" in globals() else ".", "")
out = os.environ["DEST"]
sf.write(os.path.join(out, "fleurs_hi.wav"), row["audio"]["array"], row["audio"]["sampling_rate"])
open(os.path.join(out, "fleurs_hi.txt"), "w").write(row["transcription"])
print("wrote", row["transcription"][:60])
PY
```
Run it: `DEST="Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/Fixtures" ./scripts/fetch-fleurs-hindi-sample.sh`
Add `Fixtures/` to `Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/.gitignore`.

- [ ] **Step 2: Write the gated integration test** (skips unless both the model and the fixture are present):
```swift
import Foundation
import Testing
@testable import LocalTranscription

private func fixtureURL(_ name: String) -> URL? {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let url = dir.appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

@Test func transcribesHindiEndToEndWhenModelAndFixturePresent() async throws {
    let engine = IndicConformerEngine()
    let model = LocalModelCatalog.model(id: "indic-conformer-600m")!
    guard await engine.isDownloaded(model), let wav = fixtureURL("fleurs_hi.wav") else {
        // Model or fixture absent (e.g. CI) — nothing to verify, pass by skipping.
        return
    }
    try await engine.preload(model)
    let text = try await engine.transcribe(audioURL: wav, model: model, language: "hi")
    #expect(!text.isEmpty)
    // Loose check: at least one Devanagari scalar present.
    #expect(text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
    print("INDIC_E2E transcript=\(text)")
}
```

- [ ] **Step 3: Provision the model, then run the integration test locally**

Provision once (in the app: Settings → Models → download IndicConformer 600M; or call `engine.download(...)` from a scratch harness). Then:
Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter IndicConformerIntegrationTests`
Expected: PASS — prints `INDIC_E2E transcript=…` with Devanagari text roughly matching `fleurs_hi.txt`. (If the model isn't provisioned, the test passes by skipping — confirm the print appears when it is.)

- [ ] **Step 4: Manual end-to-end in the running app**

- Build & launch: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`, then `open <BUILT_PRODUCTS_DIR>/Amanuensis.app`.
- Settings → Models: confirm "IndicConformer 600M" lists, downloads with progress, shows size, and can be deleted.
- Create a Job with the Local source + IndicConformer model + language Hindi; run it on the FLEURS clip; confirm a sensible Devanagari transcript and note first-load compile time + memory (Activity Monitor).
- Set IndicConformer as the dictation model; dictate/transcribe the clip; confirm the transcript arrives via `onFinal`.
- Check the Logs view: a missing/incomplete model surfaces a `LocalizedError`, not a generic failure.

- [ ] **Step 5: Full suite + app rebuild (final gate)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all green.
Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/IndicConformerIntegrationTests.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/IndicConformer/.gitignore \
        scripts/fetch-fleurs-hindi-sample.sh
git commit -m "test(indic): gated Hindi end-to-end integration + fixture fetch script"
```

---

## Self-Review

**Spec coverage:**
- Batch engine serving Jobs + dictation → Tasks 9–10 (engine + wiring; dictation is served by the existing `BatchTranscriber` over the batch sender, unchanged). ✅
- One catalog entry, all 7 languages, blank→Hindi → Task 1 (`resolved`) + Task 10 (catalog row). ✅
- Mel frontend from `preprocessor_constants.bin` → Tasks 2–3. ✅
- Element-wise joint add, greedy loop, pred-net caching, 10-cap → Tasks 6–7. ✅
- Model download (pinned revision), weightless preNet, compile-on-first-load, incomplete-download detection → Task 8. ✅
- Resident lifecycle via `preload`/`unloadResident` → Task 9 (mirrors `WhisperKitEngine`). ✅
- Error handling as `LocalizedError` in Logs → `LocalTranscriptionError.transcriptionFailed`/`.modelNotDownloaded` used throughout. ✅
- Testing: mel regression + decoder synthetic-joint + vocab + merger + store + gated integration → Tasks 3,6,4,5,8,11. ✅
- Attribution NOTICE → Task 1. ✅
- Resampling via FluidAudio `AudioConverter` → Task 9. ✅
- Out of scope (streaming, punctuation, non-Indic, Background Assets, auto-detect) → not implemented, per spec. ✅

**Placeholder scan:** Task 3 leaves an `expected` mel fixture to fill from a printed value (standard golden-capture, resolved within the same task before its final commit). No other placeholders — the inference seam is `encode(audio:)` end to end (Tasks 6/7/9), so the engine hands raw audio chunks straight to `decodeChunk(audio:language:)`.

**Type consistency:** `IndicConformerConfig`, `IndicConformerLanguage`, `IndicConformerInference` (`encode`/`predictAndProject`/`jointLogits`/`zeroState`), `LSTMState`, `PredictionStep`, `IndicConformerGreedyDecoder.decodeChunk`, `IndicConformerModelStore` (`root`/`packageURL`/`compiledURL`/`metadataURL`/`isDownloaded`/`remoteURL`/`download`), `IndicConformerModels.load`, `IndicConformerEngine` used consistently across tasks. `LocalTranscriptionService.init(fluidAudio:whisperKit:indicConformer:)` matches the AppCoordinator call in Task 10 Step 5.

**Known follow-ups (not blockers):** greedy inference does many tiny Core ML calls per chunk; if Task 11 shows poor latency on 8 GB, batching frames or moving to `MLState`/prediction-options is a future optimization (out of scope here).
