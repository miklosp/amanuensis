# Local speaker diarization — design

> **Status:** approved design (brainstorming complete) — ready for an implementation plan.
> **Date:** 2026-07-05.
> **Goal:** attribute transcribed speech to distinct speakers ("who said what") on-device,
> for **batch** local-transcription jobs, with **no new dependency** and **no user
> configuration** of the scenario.

This is the on-device diarization companion to
`docs/local-transcription-backend-research.md` (which established the local ASR backends and
integration seams) and reuses the same batch `AudioJobSending` path.

---

## 1. Scope

**In scope**

- **Batch only** — diarize a *finished* recording via the Jobs path. Live/streaming dictation
  is untouched.
- **Anonymous** — label distinct voices `Speaker 1 / Speaker 2 / …` within a single recording.
  Labels are per-recording; they carry no meaning across recordings.
- **Automatic** — unknown speaker count, any scenario (1:1 call, group call, in-room single
  mic, imported audio), with no user-facing "what kind of recording is this?" switch.
- A prerequisite **recording-storage change**: keep the separate mic/system tracks as FLAC so
  the channel-aware phase (§5) has them.

**Deferred (explicitly out of scope)**

- **Persistent speaker identity / recognition** across recordings (enrollment, a voice gallery,
  renaming speakers). It needs a transcript-viewing/renaming/profiles UI surface that does not
  exist yet. When built, it will reuse the per-segment voice embeddings the diarizer already
  produces (`TimedSpeakerSegment.embedding`).
- **Live / streaming diarization** — a different, harder problem (global clustering needs the
  whole recording) tied to the `DictationTranscriber` seam, not this one.

---

## 2. Background — why this is low-friction here

Three facts about the current codebase settle the design:

1. **FluidAudio (pinned `0.15.4`, already linked by the `LocalTranscription` target) ships a
   full, unused diarization API.** No new dependency. Relevant public types:
   - `DiarizerManager` — the classic cascade: **pyannote segmentation** (speaker turns +
     overlap) → **wespeaker embedding** (per-segment voice vector) → **clustering** (groups
     embeddings into an arbitrary, auto-detected number of speakers). Both models are Core
     ML/ANE, MIT-licensed, no extra entitlement.
   - `SortformerDiarizer` — an end-to-end neural alternative. **Not used** here: it has a fixed
     max-speaker ceiling (~4), wrong for "any scenario / unknown N."
   - `DiarizerConfig`, `DiarizationResult`, `TimedSpeakerSegment { speakerId: String;
     embedding: [Float]; startTimeSeconds/endTimeSeconds: Float; qualityScore: Float }`.

2. **Diarization is independent of the ASR engine.** The diarizer runs on the raw audio and
   returns time-stamped speaker turns; it never sees the words. So it pairs with **any** ASR.
   The only coupling is **timestamps**: the transcript must carry word/segment times to join
   against the speaker turns (`word@3.9s` → the turn spanning `3.9s`). This is exactly what
   WhisperX does on the Python side (Whisper + pyannote + time alignment); this design is its
   on-device Swift equivalent.

3. **`combined.flac` is already 16 kHz mono** (`CombinedFLACExporter` mono-sums mic+system) —
   which is precisely the diarizer's native input format, so blind diarization needs no
   resampling. The trade-off: the mono sum **destroys** the mic/system channel separation, so
   "which of these voices is *you*" is unrecoverable from `combined.flac` alone. That is what
   §5 (channel-aware) fixes, and why §4 (Part 1) preserves the separate tracks.

**Current pinch point:** the whole local pipeline is `String`-only —
`LocalTranscriptionEngine.transcribe(...) → String`, written straight to a `.txt`. There is no
structured transcript with timestamps to align against. Surfacing timestamps from the ASR is
the one unavoidable engine change (§4, Part 2).

---

## 3. Phasing

- **Phase A (MVP):** blind diarization of `combined.flac`. One code path; always works
  (imported audio and old recordings fall through here too); proves the diarize → align →
  render seam end-to-end.
- **Phase C (fast follow):** channel-aware diarization using the separate mic/system tracks —
  exact "you vs. them", free overlap handling — with Phase A as the automatic fallback.

Phase A is the honest foundation because C *always* needs A as its fallback, so no work is
thrown away. Part 1 (below) is groundwork shipped alongside A so that C has its inputs.

---

## 4. Part 1 — recording storage: three FLACs + two retention toggles

**Today:** live capture writes `mic.caf` + `system.caf`; `CombinedFLACExporter` mono-sums them
to `combined.flac`; the raw `.caf` are kept-or-deleted by the existing `keepOriginalCAF`
setting (default `true`).

**New:** after capture, produce **three FLACs** — `mic.flac`, `system.flac`, `combined.flac`
(all 16 kHz mono; `combined.flac` unchanged) — then apply retention:

| Artifact | Governed by | Default |
|---|---|---|
| `combined.flac` | always produced, always kept | — |
| `mic.flac`, `system.flac` | **new** toggle "Keep separate mic & system tracks" | **on** |
| `mic.caf`, `system.caf` | **existing** `keepOriginalCAF` ("Keep original .caf recordings") | **off** (flipped from `true`) |

The two toggles are independent and serve different needs: the per-track **FLACs** are the
diarization-ready, compact tracks (16 kHz mono) kept by default; the raw **`.caf`** are the
only *native-rate* copies, retained as an archival escape hatch.

**Touch points**

- `RecordingStorage/RecordingStore.swift` — `RecordingFolder` gains `micFlacURL` /
  `systemFlacURL`.
- `RecordingCore/CombinedFLACExporter.swift` (or a sibling step invoked by
  `RecordingConversionService`) — encode each source track to its own 16 kHz mono FLAC (no
  summing), in addition to the existing mono-sum. Reuse the existing FLAC-write path.
- `RecordingCore/RecordingConversionService.swift` — `startConversion` grows a
  `keepSeparateTracks: Bool` parameter parallel to `keepSourcesOnSuccess`; delete
  `mic.flac`/`system.flac` when false (mirroring the existing `.caf` deletion).
- `AppSettings/AppSettings.swift` — new `keepSeparateTracks` (default `true`); **flip
  `keepOriginalCAF` default from `true` to `false`** (only affects users who never set it — the
  stored-value check at `AppSettings.swift:77-78` preserves an explicit prior choice).
- `Amanuensis/UI/SettingsView.swift` — new toggle row; the existing `.caf` row stays.
- `Amanuensis/AppCoordinator.swift` — thread `settings.keepSeparateTracks` into
  `startConversion`.

**Scope:** applies to **new** recordings only. Old recordings keep whatever they have; those
with only `combined.flac` simply use the Phase-A blind path. No migration.

---

## 4b. Part 2 — diarization MVP (Phase A)

**Invocation — always on, no toggle.** Batch local-transcription jobs run diarization
automatically. There is no preset field and no `JobShape` change. Rationale: attribution is
almost always wanted, and single-speaker audio degrades gracefully (below), so a toggle is
needless plumbing.

**Rendering rule (this is what makes "always on" safe):**
- Diarizer returns **1 speaker** (or the ASR engine can't provide timestamps, or diarization
  fails) → return the **plain transcript, no labels** — identical to today's output. A solo
  voice memo looks untouched.
- Diarizer returns **≥2 speakers** → render `"Speaker 1: …\nSpeaker 2: …"` grouped by turn via
  the **existing** `AudioPipelineJobs/SpeakerTranscript.formatSpeakerRuns` helper (already used
  by the cloud handlers).

Output is still a `String` written to the same `.txt`. **No new output type, no storage or UI
changes downstream.**

**Pipeline** (inside `LocalTranscriptionService`, off-main — it is already an `actor`; heavy
work dispatched per the research doc's §8.4 concurrency rule):

1. Decode `combined.flac` (16 kHz mono Int16 → Float samples).
2. Run `DiarizerManager` with default `DiarizerConfig` (arbitrary N via clustering) →
   `[TimedSpeakerSegment]`.
3. Run the ASR with **word timestamps**.
4. Align: for each transcribed word, assign the `speakerId` of the `TimedSpeakerSegment` whose
   `[startTimeSeconds, endTimeSeconds]` contains the word's midpoint (nearest-segment fallback
   when a word falls in a gap).
5. Render per the rule above → `String`.

**Engine contract change — additive, minimal.** Keep
`LocalTranscriptionEngine.transcribe(...) → String` exactly as is. Add a separate
timestamped path (e.g. `transcribeTimed(...) → [TimedWord]`, where
`TimedWord { text: String; start: Double; end: Double }`) implemented **only by
`WhisperKitEngine`** for now (set WhisperKit's `wordTimestamps: true` and surface the segment
words it currently discards). `LocalTranscriptionService` calls `transcribeTimed` when it will
diarize; engines that don't implement it (Parakeet, SenseVoice, Cohere, IndicConformer) cause
diarization to be skipped and the plain `transcribe` path to be used — no error, just
un-labeled output.

**MVP limits (intentional):**
- **ASR = WhisperKit only** for diarized output (multilingual, ready word timestamps). Other
  local engines keep producing plain transcripts until their timestamp path is added.
- **Diarizer = `DiarizerManager`** (clustering / unknown N), not `SortformerDiarizer`.
- Whisper's timestamps are slightly coarse at exact turn boundaries (this is why WhisperX adds
  a forced-alignment model). Acceptable for sentence-level attribution; tighter word-level
  boundaries (via a transducer ASR like Parakeet, or forced alignment) is a later refinement.

**Touch points**

- `LocalTranscription/LocalTranscriptionEngine.swift` — add `transcribeTimed` (+ `TimedWord`).
- `LocalTranscription/WhisperKitEngine.swift` — implement it.
- `LocalTranscription/LocalTranscriptionService.swift` — orchestrate diarize + align + render;
  own diarizer-model load/warm (small, alongside the resident ASR model).
- New diarization wrapper (e.g. `LocalTranscription/SpeakerDiarizer.swift`) around FluidAudio's
  `DiarizerManager`, and an aligner (e.g. `SpeakerAlignment.swift`).
- Reuse `AudioPipelineJobs/SpeakerTranscript.formatSpeakerRuns` for rendering.
- Model download/management: the diarizer's Core ML models fetch like the ASR models
  (`ModelStorage`); surface in the existing Models flow.
- Gating: unchanged — `LocalModelSupport.isSupported` already keeps all local code dormant on
  Intel; the diarizer inherits that gate.

---

## 5. Part 3 — channel-aware diarization (Phase C, fast follow)

Once Part 1 ships (so `mic.flac`/`system.flac` exist by default) and Phase A is proven:

- **`system.flac`** → run `DiarizerManager` for the remote participants (Speaker 1..N).
- **`mic.flac`** → normally one cluster → label **"You"**. *Open refinement (the
  multi-speaker-mic case):* also run the diarizer on the mic track; if it yields >1 cluster
  (multiple in-room people on one mic), treat the extra clusters as additional speakers
  alongside "You". Cost: one extra diarizer pass on the mic track. Final decision deferred to
  C's implementation.
- **In-room / no system track** → diarize `mic.flac` acoustically (same as blind, but on the
  mic-only track).
- Transcribe `combined.flac` **once** with word timestamps; attribute each word to
  You/Speaker-N by time on the shared recording clock (the tracks share one timeline, so a
  single ASR pass suffices — no per-track transcription cost).
- **Fallback:** when the separate tracks are absent (retention off, imported audio, old
  recording) → Phase A blind path automatically.

Phase C's payoff is the common call case: exact "you vs. them" and free handling of overlap
between you and the remote (they're on different tracks, so the mono-sum failure mode of Phase
A disappears).

---

## 6. Testing strategy

- **SPM unit tests** (deterministic, no models):
  - **Alignment** — synthetic `[TimedWord]` + `[TimedSpeakerSegment]` fixtures → assert correct
    speaker assignment, gap/boundary/overlap handling, nearest-segment fallback.
  - **Rendering rule** — 1 speaker → plain text (no labels); ≥2 → `formatSpeakerRuns` output.
  - **Retention** — `RecordingConversionService` produces/keeps/deletes the right files for each
    `(keepSeparateTracks, keepOriginalCAF)` combination (gate on the sandbox `trashItem`/remove
    probe already used elsewhere).
- **App-hosted / gated integration** (real models, opt-in like the Indic E2E test): a known
  multi-speaker fixture clip → assert ≥2 speakers detected and a plausible turn structure.
  Keep it in the silently-skipping style (`AMANUENSIS_MODELS_DIR` override) so `swift test`
  stays green without the model present.
- After SPM green, **rebuild the app target** (per CLAUDE.md — `swift test` doesn't compile the
  app).

---

## 7. Open questions / risks

1. **`.caf` default vs. disk usage — RESOLVED (2026-07-05).** With separate FLAC tracks kept by
   default, keeping `.caf` too stored `.caf` + 3 FLACs per recording — redundant for most users.
   **Decision: flip `keepOriginalCAF` default to `false`** (the FLAC tracks cover the "separate
   tracks" need; `.caf` becomes opt-in for native-rate archival). Reflected in §4.
2. **`DiarizerConfig` tuning.** The clustering threshold / min-speaker settings drive
   over- vs. under-segmentation (splitting one person into two, or merging two into one).
   Needs a spike on real recordings; defaults first, tune from there.
3. **Cold-start cost.** Running ASR *and* the two diarizer models adds first-run Core ML
   compile + steady-state memory. Measure on the 8 GB target before assuming it's free.
4. **Diarizer weight licences.** Confirm the pyannote-segmentation and wespeaker weights
   FluidAudio ships are cleared for a paid app (same class of check as the Parakeet/NVIDIA
   weight question already tracked in the research doc).
5. **Whisper timestamp precision at turn boundaries** (see §4b) — accept for MVP; revisit if
   attribution accuracy at fast back-and-forth turns proves inadequate.

---

## 8. Non-goals recap

No persistent speaker identity, no live/streaming diarization, no new `JobShape`, no new
persisted transcript type, no diarization UI beyond the existing Settings toggle and Models
management. The feature's entire user-visible surface is: better `.txt` output for
multi-speaker recordings, plus one new Settings toggle.
