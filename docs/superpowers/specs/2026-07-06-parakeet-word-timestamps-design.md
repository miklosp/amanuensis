# Parakeet word timestamps → local diarization + per-turn timestamps

> **Status:** designed 2026-07-06, ready for a plan.
> **Scope:** Parakeet family only (`tdtCtc110m`, `v3`, `tdtJa`).
> **Parent:** implements §1 of `2026-07-06-local-diarization-followups.md`; companion to the
> Phase A design `2026-07-05-local-diarization-design.md`.

## Goal

Give Parakeet-family models the same diarized + per-turn-timestamped transcript output that
WhisperKit already produces, by implementing the one method the orchestration needs:
`transcribeTimed(...) -> [TimedWord]`.

## Why this is small

`transcribeDiarized` (in `LocalTranscriptionService`) already does everything downstream:

```
transcribeTimed() -> [TimedWord]
  → attributeSpeakers(words, diarizerSegments)   // speaker per word, merged into runs
  → single speaker?  → plain transcript
  → multi speaker?   → "[mm:ss] Speaker N: …"
  → engine can't time? (.timestampsUnsupported) → plain transcript
  → diarize failed?  → plain transcript (cancellation is re-thrown)
```

So implementing `transcribeTimed` on `FluidAudioEngine`'s Parakeet branch unlocks **both**
speaker labels and per-turn timestamps. **No changes** to `LocalTranscriptionService`,
`LocalTranscriptionSender`, `SpeakerAlignment`, the formatter, or any UI. WhisperKit is "done"
only because it is the sole engine implementing `transcribeTimed` today.

## Feasibility across the remaining engines (why Parakeet only)

| Model(s) | Engine | Audio timestamps available? | This round |
|---|---|---|---|
| Parakeet `tdtCtc110m` / `v3` / `tdtJa` | FluidAudio | **Yes** — `ASRResult.tokenTimings` (per-token `startTime`/`endTime`) | **In scope** |
| SenseVoice Small | FluidAudio | No — `SenseVoiceManager.transcribe` returns only `String` | Stays plain (unchanged) |
| Cohere Transcribe | FluidAudio | No — `TranscriptionResult` exposes only compute-timing (`encoderSeconds`/`decoderSeconds`/`totalSeconds`), not audio timestamps | Stays plain (unchanged) |
| IndicConformer 600M | in-house RNN-T | Derivable from decoder frame indices, but the greedy decoder discards them; needs decoder change + frame-stride calibration | Deferred (net-new scope, calibration risk) |
| Whisper large-v3-turbo | WhisperKit | Already implemented | Done |

SenseVoice and Cohere already degrade to plain automatically via the orchestration's
`.timestampsUnsupported` branch — no work is needed for them; they simply cannot produce
timestamps without reaching into FluidAudio internals.

## Design

### 1. Engine method — one shared ASR call, two readers

The Parakeet branch of `transcribe` and the new `transcribeTimed` must run the **identical**
ASR call (same resident/transient manager resolution, same `TdtDecoderState(decoderLayers:)`,
same v3-only language conditioning) and differ only in what they read off the `ASRResult`.
WhisperKit's `transcribe`/`transcribeTimed` already drifted apart by copy-paste; this design
avoids repeating that.

- Extract a private helper on `FluidAudioEngine`:
  `runParakeet(_ model: LocalModel, language: String?) async throws -> ASRResult`
  holding the shared manager-resolution + `asr.transcribe(_:decoderState:language:)` call.
- `transcribe` (Parakeet branch) → `runParakeet(...).text` (behavior unchanged).
- `transcribeTimed` (new override on `FluidAudioEngine`) switches on `model.runner`:
  - `.fluidAudioParakeet` → `groupParakeetWords(runParakeet(...).tokenTimings ?? [])`
  - `.fluidAudioSenseVoice`, `.fluidAudioCohere` → `throw .timestampsUnsupported(model.displayName)`
- `transcribeTimed` keeps the existing `isDownloaded` guard the other engine methods use.

### 2. The crux — token→word grouping (pure, unit-tested)

Parakeet emits SentencePiece **sub-word** tokens (`▁hel`, `lo`), not words. Feeding the aligner
raw sub-word fragments would attribute fragments to speakers and render text with spurious
spaces. A pure function converts token timings to word timings:

`internal func groupParakeetWords(_ timings: [TokenTiming]) -> [TimedWord]`

Rules (mirrors FluidAudio's own internal `VocabularyRescorer.buildWordTimings`, which is
`internal` and therefore not callable):

- A token whose text starts with `▁` (U+2581) or an ASCII space **begins a new word**; the
  first non-special token also begins a word. Other tokens append to the current word.
- Skip special/empty tokens (`""`, `<blank>`, `<pad>`).
- Word `start` = first sub-token's `startTime`; word `end` = last sub-token's `endTime`.
- **Spacing convention:** emit each word as `" " + strippedText` (boundary prefix stripped),
  matching WhisperKit's leading-space convention so the pipeline's
  `words.map(\.text).joined()` reconstructs the transcript with correct inter-word spacing.
  The leading space on the first word is trimmed downstream (`transcribeDiarized` trims the
  joined plain string; `attributeSpeakers` trims each run).
- **Empty guard:** if `tokenTimings` is nil/empty, the function returns `[]`, and
  `transcribeTimed` throws `.timestampsUnsupported` — routing to the faithful `result.text`
  plain path rather than emitting an empty transcript.

Location: a new `ParakeetWordGrouping.swift` alongside `SpeakerAlignment.swift`. It takes
FluidAudio's `TokenTiming` directly — the module already imports FluidAudio, and `TokenTiming`
has a public init so tests construct cases without a parallel DTO.

### 3. Testing

- **Unit (deterministic, no models)** — `ParakeetWordGroupingTests`:
  - multi-token word: `▁hel` + `lo` → `[" hello"]`, start = first, end = last
  - multiple words across `▁`- and space-prefixed boundaries
  - special/empty tokens skipped
  - empty input → empty output
  - a single continuation-only sequence (defensive: first token has no boundary marker)
- **Gated E2E (real model, opt-in, silent-skip)** — extend the `DiarizationE2ETests` pattern
  (env-var fixture, skip if unset/missing): run a real Parakeet model on a 2-speaker fixture,
  assert `transcribeTimed` returns words with monotonic, in-range timestamps and that the
  diarized output resolves ≥2 speakers. This is the empirical confirmation that `tokenTimings`
  is populated **per version** (`tdtCtc110m` / `v3` / `tdtJa`).

## Risks

- **`tokenTimings` is `Optional`.** Handled by the empty→`.timestampsUnsupported`→plain
  degradation; the E2E confirms which versions populate it. The default English model
  (`tdtCtc110m`) is transcribed through FluidAudio's **TDT** decoder (we already build a
  `TdtDecoderState` for it), which is the path that fills `tokenTimings`, so it is expected to
  work — but the E2E is the proof.
- **Boundary accuracy.** Parakeet's transducer timestamps are typically *tighter* than
  Whisper's, so turn-boundary attribution should be at least as good as the WhisperKit baseline.
  Parakeet is purely additive — no regression risk to existing paths.
- **Fallback text fidelity.** On single-speaker or diarize-failure, the emitted plain text is
  the grouping's reconstruction (identical property to WhisperKit today). The hard
  `.timestampsUnsupported` path still returns the faithful `result.text`.

## Out of scope

- IndicConformer timestamps (deferred — see the feasibility table).
- SenseVoice / Cohere timestamps (blocked at the FluidAudio API boundary).
- Any diarizer model-management UI, Phase C channel-aware diarization, or perf items — tracked
  in `2026-07-06-local-diarization-followups.md`.
