# Local transcription — FluidAudio + WhisperKit API reference

> **Status:** API reference for the on-device transcription implementation. Compiled
> 2026-06-30 from FluidAudio `main` (HEAD `a95ec26`, 2026-06-28) and WhisperKit `main`.
> Sizes pulled same-day from `huggingface.co/api`. Companion to
> `docs/local-transcription-backend-research.md` (the why) and
> `docs/superpowers/plans/2026-06-30-local-transcription.md` (the how).

> **Two gotchas that will bite if ignored:**
> 1. **FluidAudio's README/GettingStarted are stale.** They show `asrManager.transcribe(samples)`;
>    the real API requires `decoderState: inout TdtDecoderState` on every overload. Code written
>    against the docs won't compile — use the source signatures below.
> 2. **WhisperKit defaults its model store to `~/Documents/huggingface/…`** — undesirable under
>    App Sandbox. **Override `downloadBase` to Application Support.** (FluidAudio defaults to
>    Application Support already.)
> 3. **Neither library exposes list/delete/size APIs in OSS.** We manage the directories ourselves
>    (FluidAudio gives `modelsExist` + `clearModelCache`; WhisperKit gives nothing — `FileManager`).

---

## A. FluidAudio (`github.com/FluidInference/FluidAudio`, product `FluidAudio`)

### A1. Load & download (auto-downloads from HF, with progress)

```swift
import FluidAudio

// Download-if-absent + load. Default version is .v3.
let models = try await AsrModels.downloadAndLoad(version: .v3) { p in
    // p.fractionCompleted: Double ; p.phase: .listing | .downloading | .compiling
}
let asr = AsrManager(config: .default)
try await asr.loadModels(models)
```

`AsrModels` statics (`Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift`):

```swift
@discardableResult
static func download(to directory: URL? = nil, force: Bool = false,
                     version: AsrModelVersion = .v3,
                     encoderPrecision: ParakeetEncoderPrecision = .int8,   // .int8 | .int4 (v3)
                     progressHandler: DownloadUtils.ProgressHandler? = nil) async throws -> URL
static func downloadAndLoad(to:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:) async throws -> AsrModels
static func load(from directory: URL, ...) async throws -> AsrModels          // no network
static func modelsExist(at:version:encoderPrecision:) -> Bool
static func isModelValid(version:encoderPrecision:) -> Bool                    // compiles to verify
static func defaultCacheDirectory(for version: AsrModelVersion) -> URL
```

`ProgressHandler = @Sendable (DownloadProgress) -> Void`; `DownloadProgress.fractionCompleted: Double`,
`.phase: .listing | .downloading(completedFiles:totalFiles:) | .compiling(modelName:)`.
**Called on an unspecified queue → hop to MainActor for UI.** Download timeout 30 min.

- **SenseVoice:** `let sv = try await SenseVoiceManager.load(precision: .fp16)` (own auto-download).
- **Cohere:** **no auto-download** — stage with `DownloadUtils.downloadRepo(.cohereTranscribeCoreml, …)`
  then `CoherePipeline.loadModels(encoderDir:decoderDir:vocabDir:…)`.

### A2. Storage & deletion

Location: `~/Library/Application Support/FluidAudio/Models/<repo-folder>/` (configurable via
`to:`/`from:` URL). Under App Sandbox this is the container's Application Support.

```swift
AsrModels.modelsExist(at: dir, version: .v3, encoderPrecision: .int8)         // (a) installed?
DownloadUtils.clearModelCache(forRepo: .parakeetV3, directory: parentDir)     // (b) delete one
DownloadUtils.clearAllModelCaches()                                           // delete all
// (c) size: NO API — walk the folder with FileManager and sum file sizes.
```

### A3. Transcribe

Input: `[Float]` **mono, 16 kHz**, normalized [-1, 1], ≥ ~300 ms. Helper:
`AudioConverter().resampleAudioFile(_ url: URL) throws -> [Float]` (handles FLAC/M4A/MP3, bit depth, channels).

`AsrManager` is an `actor`:

```swift
func transcribe(_ audioSamples: [Float], decoderState: inout TdtDecoderState,
                language: Language? = nil) async throws -> ASRResult
func transcribe(_ url: URL, decoderState: inout TdtDecoderState, language: Language? = nil) async throws -> ASRResult
func transcribeDiskBacked(_ url: URL, decoderState: inout TdtDecoderState, ...)   // constant-mem long files
```

```swift
let samples = try AudioConverter().resampleAudioFile(fileURL)
var state = try TdtDecoderState(decoderLayers: asr.decoderLayerCount)   // init(decoderLayers: Int = 2)
let result = try await asr.transcribe(samples, decoderState: &state)
// result.text, .confidence, .duration, .processingTime, .rtfx, .tokenTimings
```

`language:` honored **only on v3** (ignored for v2/110m/ja). Audio > ~30 s (480 000 samples) is
chunked internally by `ChunkProcessor`; progress via `asr.transcriptionProgressStream`
(`AsyncThrowingStream<Double, Error>`). `ASRResult.text: String` is what we return.
(SenseVoice/Paraformer return a bare `String`; Cohere returns its own struct.)

### A4. Manager per model

One `AsrManager` for the whole Parakeet TDT family, selected by `AsrModelVersion`:

| Model | Manager | Selector |
|---|---|---|
| Parakeet TDT v3 (multilingual, default) | `AsrManager` | `.v3` |
| Parakeet TDT v2 (English) | `AsrManager` | `.v2` |
| Parakeet TDT-CTC-110M (English) | `AsrManager` | `.tdtCtc110m` |
| Parakeet TDT Japanese | `AsrManager` | `.tdtJa` |
| Cohere Transcribe | `CoherePipeline` (actor) | stage repo + `loadModels` |
| SenseVoiceSmall | `SenseVoiceManager` (actor) | `.load(precision:)` |

### A5. Cohere — 35 s/call cap (confirmed)

`CohereAsrConfig`: `maxAudioSeconds = 35.0`, `maxSamples = 560_000`, `chunkOverlapSeconds = 5.0`,
`chunkHopSeconds = 30.0`. Plain `transcribe` **silently truncates > 35 s**;
**`transcribeLong(...)`** chunks (30 s hop / 5 s overlap, LCS-stitched). Use `transcribeLong`
for recordings. Language passed explicitly (`CohereAsrConfig.Language`, 14 values).

---

## B. WhisperKit (`github.com/argmaxinc/WhisperKit`, product `WhisperKit`)

### B1. Download & management

```swift
static func download(variant: String, downloadBase: URL? = nil, useBackgroundSession: Bool = false,
                     from repo: String = "argmaxinc/whisperkit-coreml", token: String? = nil,
                     endpoint: String = Constants.defaultRemoteEndpoint,
                     progressCallback: ProgressCallback? = nil) async throws -> URL    // @Sendable (Progress) -> Void
```

Usually you let the init download: `WhisperKit(WhisperKitConfig(model:downloadBase:))` runs
download → prewarm → load. **No list/delete/size API** — hand-roll:

```swift
// list / delete: scan & remove the variant subfolder under downloadBase
let dir = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
let installed = try FileManager.default.contentsOfDirectory(atPath: dir.path)
try FileManager.default.removeItem(at: dir.appendingPathComponent(variant))
```

**Storage:** default `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>/`.
**Override `downloadBase`** to Application Support (sandbox):

```swift
let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Amanuensis/Models/WhisperKit")
let pipe = try await WhisperKit(WhisperKitConfig(model: "large-v3-v20240930_626MB", downloadBase: base))
```

### B2. Transcribe

```swift
func transcribe(audioPath: String, decodeOptions: DecodingOptions? = nil,
                callback: TranscriptionCallback? = nil) async throws -> [TranscriptionResult]
func transcribe(audioArray: [Float], decodeOptions: DecodingOptions? = nil, ...) async throws -> [TranscriptionResult]
```

`audioPath` auto-loads + resamples (wav/mp3/m4a/flac → 16 kHz mono Float32) — feed it the
`combined.flac` path directly. `TranscriptionResult.text` (+ `.segments`, `.language`).

```swift
let results = try await pipe.transcribe(audioPath: url.path,
    decodeOptions: DecodingOptions(language: "en", chunkingStrategy: .vad))
let text = results.map(\.text).joined(separator: " ")
```

### B3. Whisper identifiers + sizes (HF folder names; `openai_whisper-` prefix optional)

| Identifier | What | On-disk |
|---|---|---|
| `openai_whisper-large-v3-v20240930_626MB` | large-v3-turbo, quantized — **recommended default** | ~627 MB |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | large-v3-turbo + Argmax turbo decoder (macOS max-speed) | ~632 MB |
| `openai_whisper-large-v3-v20240930` | large-v3-turbo, float16 | ~1.62 GB |
| `openai_whisper-large-v3` | large-v3 full, float16 | ~3.09 GB |
| `openai_whisper-large-v3_947MB` | large-v3 quantized | ~947 MB |
| `openai_whisper-base` / `-tiny` | dev/debug | ~139 / 57 MB |

Provision ~2× model size during install (download + extract).

---

## C. Models-page metadata (the six v1 models)

| Model | Package / manager | Selector / identifier | On-disk | Languages | One-liner |
|---|---|---|---|---|---|
| **Parakeet TDT-CTC-110M** *(recommended)* | FluidAudio / `AsrManager` | `.tdtCtc110m` | ~217 MB | English | Tiny & fastest (96× RTF, 3.0% WER) |
| **Parakeet TDT v3** | FluidAudio / `AsrManager` | `.v3` | ~460 MB (int8) | 25 European (auto-detect) | Multilingual default; ~110× RTF |
| **Cohere Transcribe** | FluidAudio / `CoherePipeline` | stage repo + `loadModels` | ~2.09 GB | 14 (incl. ja/zh/ko/vi/ar) | High-accuracy encoder-decoder; **35 s/call → `transcribeLong`** |
| **Whisper large-v3-turbo** | WhisperKit | `openai_whisper-large-v3-v20240930_626MB` | ~627 MB | 99 | Recommended Whisper; near-v3 accuracy, fast |
| **Parakeet TDT Japanese** | FluidAudio / `AsrManager` | `.tdtJa` | ~590 MB | Japanese | 6.85% CER (JSUT) |
| **SenseVoiceSmall** | FluidAudio / `SenseVoiceManager` | `.load(precision:.fp16)` | ~450 MB (fp16) | 50+ (zh/yue/en/ja/ko) | Non-autoregressive multilingual |

(Optional later: Whisper `large-v3` full ~3.09 GB for the overnight-quality tier.)

---

## D. SPM dependencies

```swift
// Packages/AudioPipeline/Package.swift — dependencies (verify latest tags at add-time)
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),      // product "WhisperKit"
.package(url: "https://github.com/FluidInference/FluidAudio", from: "0.12.0"), // product "FluidAudio"
```

Both download over HTTPS from Hugging Face → covered by the existing
`com.apple.security.network.client` entitlement; **no new entitlement**. Models write to
Application Support (app container) — writable under App Sandbox. Inference runs on the ANE/GPU
off-main (FluidAudio `AsrManager` is an `actor`; WhisperKit `transcribe` is `async`).

## E. Uncertainty / version flags

- FluidAudio `transcribe` requires `decoderState: inout TdtDecoderState` (docs are stale).
- Cohere repo enum (`cohere-transcribe-03-2026-coreml`) vs doc link mismatch — verify which the
  pinned version pulls.
- WhisperKit also ships via `argmaxinc/argmax-oss-swift` (v1.0.0) — identical symbols; pin to
  whatever `swift package` resolves.
- SenseVoice "50+ languages" is from docs; `language` is an `Int32` index (`0` = auto).
- Treat exact default *values* as "verify against the pinned version."
