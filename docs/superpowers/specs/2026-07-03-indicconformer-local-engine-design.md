# Add an on-device IndicConformer-600M transcription engine

**Date:** 2026-07-03
**Status:** Approved (design)

## Goal

Add **IndicConformer-600M** (AI4Bharat, MIT) as a local/on-device transcription
backend, closing the one remaining gap in the local stack: high-quality Indic-language
STT (Hindi + Bengali, Marathi, Telugu, Tamil, Malayalam, Kannada). Per the local-backend
research doc §4.3 / §11.2, this is the best-WER, cleanest-licence Hindi option (~13 WER,
MIT), but it is **not a turnkey SDK** — the inference core must be written by hand.

Scope for this PR is **batch only**. Because dictation already runs *through* the batch
sender (`BatchTranscriber` calls `onFinal` once), a batch `LocalTranscriptionEngine`
lights up **both** the Jobs path and dictation with no extra work. True streaming stays
deferred (§ "Out of scope").

Success criterion: a Hindi clip transcribes clearly-correctly end-to-end (via a Job **and**
via dictation) in the running app, with the deterministic unit tests green. No strict WER
target.

## Background: how local engines work today

The local stack is already built and shipping — merged to `main` via PR #20 (WhisperKit +
FluidAudio). The abstraction a new backend implements
(`Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift`):

```swift
public protocol LocalTranscriptionEngine: Sendable {
    func isDownloaded(_ model: LocalModel) async -> Bool
    func installedBytes(_ model: LocalModel) async -> Int64
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ model: LocalModel) async throws
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String
    func preload(_ model: LocalModel) async throws   // default no-op; real engines override
    func unloadResident() async                       // default no-op
}
```

- `LocalTranscriptionService` (actor) routes `LocalModel.runner → engine` in `resolve(_:)`
  and owns the **single-resident-model lifecycle** (`preload`/`unloadResident`/`residentModelID`,
  with delete/preload race handling).
- `LocalModel` / `LocalModelCatalog.all` is the hard-coded model catalog; `LocalRunner` is
  the engine-selector enum.
- `ModelStorage` puts everything under `Application Support/Amanuensis/Models/<runner.rawValue>/`.
- Batch: `LocalTranscriptionSender: AudioJobSending` pulls `language` from `job.fields` and
  calls `service.transcribe(...)`. Keyless carve-out is done (`JobShape.requiresAPIKey ==
  false` for `.localTranscription`).
- Dictation: `BatchTranscriber: DictationTranscriber` wraps the batch sender and emits
  `onFinal` once — so a batch engine serves dictation unchanged.
- Model-management UI (`LocalModelsStore`, `ModelsView`, `ModelRowView`, `ModelSelector`)
  is model-agnostic and needs no changes.

**Net:** adding a backend is 4 mechanical integration steps plus the engine itself. FluidAudio's
transducer decoder is **not** reusable — it is hard-bound to the Parakeet TDT model family
(fixed version enum, fixed repos). There is **no** first-party Core ML / Accelerate / mel /
RNNT-decode code in the repo to extend. The inference core is genuinely new work — but see
"Approach", where a complete MIT reference makes it close to a drop-in adaptation.

## The model artifact

`phequals/indic-conformer-600m-multilingual-coreml-rnnt` (Hugging Face, **MIT**). A quantized
Core ML RNN-T conversion of `ai4bharat/indic-conformer-600m-multilingual`. Files:

- **Encoder** — `coreml/encoder/indic_conformer_encoder_int8.mlpackage`.
- **RNN-T graph, split across packages** under `coreml/rnnt/`:
  - `indic_conformer_rnnt_decoder_reconstructed.mlpackage` — prediction net (2-layer LSTM).
  - Joint, decomposed: `indic_conformer_joint_enc`, `indic_conformer_joint_pred`,
    `indic_conformer_joint_pre_net`.
  - **7 language post-nets**: `indic_conformer_joint_post_net_{hi,bn,mr,te,ta,ml,kn}.mlpackage`.
- **Metadata**: `metadata/vocab.json`, `metadata/preprocessor_constants.bin` (STFT window, mel
  filterbank, pre-emphasis + guards; binary, magic `IASRPC01`). `config.json`,
  `language_masks.json`, and `preprocessor.ts` also ship but are **not consumed at runtime**.

The exact tensor I/O, shapes, and chaining are documented in "Resolved model contract" below
(read from the Muesli reference). `.mlmodelc` compiled dirs are intentionally **excluded** from
the repo and are compiled locally on first load.

**Reference implementation:** `pHequals7/muesli` (**MIT, © 2026 Pranav Hari**) is a working
Swift macOS app whose `IndicASRBackend.swift` (~1160 lines) is a complete, self-contained
IndicConformer RNN-T Core ML backend. It is an app, not a library — used as the **source to
port from (with attribution)**, not a binary dependency. Its only external dependency is
FluidAudio's `AudioConverter` (for resampling), which this repo already vendors.

## Approach

Chosen approach (**A** of three considered): write a first-party `IndicConformerEngine`,
**porting/adapting Muesli's `IndicASRBackend.swift` (MIT, with attribution)** onto our
`LocalTranscriptionEngine` seam. Dependency-free beyond what we already ship — `CoreML`,
`Accelerate`, and FluidAudio's `AudioConverter` — matching this repo's deliberate no-MLX /
no-ONNX stance. Because the reference is a complete implementation, this is close to a drop-in
adaptation (re-home paths, map the actor lifecycle onto the protocol, adapt progress
signatures) rather than a rewrite.

Rejected:
- **B. Hand-roll from scratch** — reinvents the mel-normalization and greedy-transducer details
  the MIT reference already provides; higher risk of subtle numerical bugs, no offsetting benefit.
- **C. sherpa-onnx / ONNX Runtime** with the ONNX IndicConformer export — abandons the INT8/ANE
  Core ML artifact, adds a heavy C-bridged dependency with library-validation friction, and
  contradicts the SPM-only setup.

## Architecture

### Integration (4 mechanical steps, no downstream changes)

1. `case indicConformer` added to `LocalRunner` (`LocalModel.swift`).
2. **One** `LocalModel` row in `LocalModelCatalog.all`: `runner: .indicConformer`,
   `languages: [hi, bn, mr, te, ta, ml, kn]`, marked recommended for Hindi. (One entry covers
   all 7 languages, exactly as WhisperKit is one entry over many languages.)
3. New `public actor IndicConformerEngine: LocalTranscriptionEngine`.
4. Route `.indicConformer → indicConformerEngine` in `LocalTranscriptionService.resolve(_:)`;
   add the third engine slot to the service `init` (wired at `AppCoordinator.swift:100`).

Everything downstream — batch sender, dictation adapter, `LocalModelsStore`, all three UI views,
resident/warm lifecycle, keyless-provider carve-out — is untouched.

### Inference core (new code, `LocalTranscription/IndicConformer/`)

`IndicConformerEngine` orchestrates; the logic lives in single-purpose, independently testable
units ported from the reference:

| Unit | Responsibility | Depends on |
|---|---|---|
| resampling | `audioURL` → 16 kHz mono `Float32` via FluidAudio's `AudioConverter().resampleAudioFile` (already a dependency; matches the reference) | FluidAudio |
| `MelFrontend` | PCM → `[80, 1024]` per-bin-normalized log-mel; pipeline: pre-emphasis → reflect-pad (256) → centered STFT (nFFT 512, win 400, hop 160) → power → 80-bin filterbank → log → **per-bin CMVN**; window/filterbank/guards read from `preprocessor_constants.bin` (magic `IASRPC01`) | Accelerate/vDSP |
| `IndicConformerModels` | Load + **compile `.mlmodelc` on first use**, hold all **12** `MLModel` handles resident (encoder, LSTM decoder, jointEnc, jointPred, jointPreNet, + 7 small per-language post-nets) | CoreML |
| `RNNTGreedyDecoder` | Per-frame greedy transducer: `jointEnc(encFrame) + jointPred(predFrame)` **element-wise add** → `jointPreNet` → `jointPostNet[lang]` → argmax over 257 (blank 256); non-blank emits + steps the 2-layer LSTM pred net; pred-net output **cached across blank frames**; 10-symbols/frame cap | CoreML |
| `IndicVocab` | `vocab.json` = per-language `[code: [token]]`; detokenize (skip blank 256, SentencePiece `▁`→space); token- and text-level overlap merge across chunks | — |

Plus `IndicConformerDownloader` (HF file fetch). **No `config.json` / `language_masks.json`
parsing** — the runtime consumes only `vocab.json` + `preprocessor_constants.bin`; per-language
post-nets already scope the output vocabulary, so no separate language mask is applied.

### Data flow

`transcribe(audioURL, model, language)`:
1. Resample → 16 kHz mono `Float32`.
2. Slice into **10 s chunks with 1 s overlap**.
3. Per chunk: `MelFrontend` → `[1, 80, 1024]` (real frames ≤ 1024) → encoder (`outputs` +
   `encoded_lengths`) → `RNNTGreedyDecoder` (requested language's post-net) → chunk token ids
   + text.
4. Merge chunks by **token-sequence overlap** (fallback: normalized word overlap) → detokenize
   → transcript `String`.

### Resident lifecycle & memory

`IndicConformerModels` *is* the resident handle; `preload`/`unloadResident` load/drop the bundle
keyed by `residentModelID` — fits the existing single-resident-model service (mirrors how
`WhisperKitEngine` holds one resident handle). Following the reference, all 12 models load
together (the 7 per-language post-nets are small heads), so language switching is instant and no
per-call model load is needed.

**Flagged risk:** 12 resident Core ML models + the 600M INT8 encoder is heavier than a single
WhisperKit bundle. On 8 GB machines this warrants a memory check and a first-load compile-cost
measurement (covered in testing). First-load `.mlmodelc` compilation is a one-time cost, cached
to disk. If memory proves tight, lazy per-language post-net loading is a fallback (heads are
independent).

## Language handling

- Normalize the incoming code (`hi`, `HI`, surrounding whitespace…) to a base code → one of the
  7 post-nets (mirrors the reference's `IndicASRLanguage.resolved`).
- **blank / nil / unsupported code → Hindi** (`hi`); never a hard error (avoids job failures on
  stray codes; the picker constrains choices anyway).
- No separate vocab mask — each language's post-net already emits only that language's logits.

## Model management

`IndicConformerDownloader` (first-party — no SDK helper covers this repo; ports the reference's
`IndicASRModelStore`):
- Downloads each required file from a **pinned revision** —
  `https://huggingface.co/<repo>/resolve/<rev>/<path>?download=1` — into
  `Application Support/Amanuensis/Models/indicConformer/` under the repo's `coreml/encoder`,
  `coreml/rnnt`, `metadata` layout, reporting progress into the protocol's `progress: (Double)
  -> Void`.
- Required per package: `Manifest.json` + `Data/com.apple.CoreML/model.mlmodel` +
  `weights/weight.bin` — **except `jointPreNet`, which is weightless** (empty `weights/` dir
  created before compile).
- Required metadata: `vocab.json` + `preprocessor_constants.bin` only.
- **First-load compile:** each `.mlpackage` → `.mlmodelc` (via `MLModel.compileModel`), cached
  alongside.
- `isDownloaded` mirrors WhisperKit's `hasRequiredModels`: all 12 packages (compiled `.mlmodelc`
  **or** raw contents present) + required metadata, so a crash-interrupted download is not
  counted as complete.
- `installedBytes` sums the on-disk tree; `delete` drops the runner dir (existing service
  delete/preload race handling applies).

## Error handling

Consistent with the existing "job failures surface full detail" convention — user-facing errors
are `LocalizedError` and appear in the Logs view:

- Missing / incomplete model download → `LocalizedError`.
- Core ML compile/load failure → `LocalizedError` naming the offending model.
- Unexpected encoder/decoder output shape → `LocalizedError` (the reference guards these with
  explicit shape checks; port them).
- Audio-decode failure → `LocalizedError`.
- Empty / silent audio (no frames) → empty string, not a crash.
- Unsupported language → Hindi fallback + log, no throw.

## Testing

- **SPM unit (no model required):**
  - `MelFrontend` reproduces golden log-mel vectors for a fixed input buffer (tolerance-bounded)
    — the reference explicitly flags this frontend as needing a golden regression test, since the
    encoder assumes an exact mel contract.
  - `RNNTGreedyDecoder` against a hand-built **synthetic joint**: blank (256) advances the
    frame, non-blank emits + steps the LSTM state, the 10-symbols/frame cap holds, and the
    pred-net cache is reused across blank frames.
  - `IndicVocab` detokenize (SentencePiece `▁`, skip blank) + two-chunk token-overlap merge.
  - Language-code → post-net mapping, including blank → hi.
  - Preprocessor-constants parsing (`IASRPC01` header, size/shape validation) + incomplete-
    download detection.
  - (Service / store / sender layers are already covered by the existing `FakeEngine` pattern —
    untouched.)
- **Gated integration test:** download the real model, transcribe a **FLEURS Hindi** clip,
  assert non-empty output + a rough substring match against the reference transcript. **Gated on
  model presence** (runtime probe) so model-less CI skips it — same pattern as the sandbox
  `trashItem` tests.
- **Manual end-to-end:** transcribe the Hindi clip via a Job **and** via dictation in the running
  app; eyeball output; note first-load compile time + memory.
- Per `CLAUDE.md`: after the SPM suite is green, **rebuild the app target** to confirm it still
  compiles.

## Out of scope

- **True streaming / partial results** — stays deferred (research doc §11.1); dictation uses the
  batch adapter.
- **Punctuation restoration** — the model does not produce it.
- **Non-Indic languages.**
- **Background Assets** delivery (§11.3) — Hugging Face download + cache is sufficient for
  Developer-ID ships.
- **Auto language detection** — the model cannot do it; language is explicit.

## Resolved model contract (from the Muesli reference)

Reading `IndicASRBackend.swift` resolved the spec's former open question. Exact I/O and chaining:

- **Encoder** `indic_conformer_encoder_int8`: in `audio_signal Float32[1,80,1024]`,
  `length Int32[1]`; out `outputs` `[1, 1024, frames]` (channels-first: dim 1 = encoderDim 1024,
  dim 2 = frames) + `encoded_lengths Int32[1]`.
- **Prediction net** `..._rnnt_decoder_reconstructed` (2-layer LSTM): in `targets Int32[1,1]`,
  `target_length Int32[1]`, `states_1 Float32[2,1,640]` (h), `cell_state_in Float32[2,1,640]`
  (c); out `outputs [1,640]`, `states` (next h), `cell_state_out` (next c). Initial `targets` =
  SOS `5632`; emitted tokens are `0…255`, blank `256`.
- **Joint**: `jointEnc(input = encoder frame [1,1,1024]) → [1,1,640]`;
  `jointPred(input = pred frame [1,1,640]) → [1,1,640]`; the two are **summed element-wise**,
  passed through `jointPreNet` (input/output `[1,1,640]`, weightless), then the per-language
  `jointPostNet[lang]` → logits; `argmax` over the first `257` (0…255 tokens + blank 256).
- **Greedy loop**: per encoder frame, up to 10 inner symbol steps; blank breaks to the next
  frame; the prediction-net output is **cached and reused across blank frames** (it depends only
  on token history, so it changes only when a token is emitted).
- **Constants** (hardcoded, matching the model): sr 16000, nFFT 512, hop 160, win 400, 80 mels,
  encoderDim 1024, predHiddenDim 640, predLayers 2; the STFT window, filterbank, and
  log/normalization guards come from `preprocessor_constants.bin` (magic `IASRPC01`).
- **Chunking**: 10 s audio chunks, 1 s overlap; per-chunk mel capped at 1024 frames; chunks
  merged by longest token-suffix/prefix overlap (≤64), falling back to normalized word-overlap
  merge on the decoded text.

The port adapts this onto `LocalTranscriptionEngine`: map the reference's
`loadModels`/`shutdown` actor onto `preload`/`unloadResident`, its `(Double, String?)` progress
onto the protocol's `(Double)`, and its `~/.cache/muesli/models` path onto `ModelStorage`.

## Attribution

Both the model and Muesli are **MIT** (Muesli © 2026 Pranav Hari) — verified from the repo
`LICENSE`. Port with attribution: a source-comment / NOTICE crediting `pHequals7/muesli` and
`phequals/indic-conformer-600m-multilingual-coreml-rnnt`.

## Branch

The scaffolding this work depends on is now on `main` (merged via PR #20), so this feature
branches off **`main`** (new branch, e.g. `feat/indicconformer-local-engine`; the session works
in place, not in a worktree, unless requested otherwise).
