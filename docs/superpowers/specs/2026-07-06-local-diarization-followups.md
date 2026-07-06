# Local diarization — follow-ups after Phase A

> **Status:** backlog / captured 2026-07-06, after Phase A merged (PR #29).
> **Purpose:** durable record of the deferred work and findings from the Phase A build +
> review + bot review + manual smoke, so none of it is lost. Companion to the design spec
> `2026-07-05-local-diarization-design.md` and the research doc
> `docs/local-transcription-backend-research.md`.

Phase A shipped: batch local Jobs diarize `combined.flac` (FluidAudio `DiarizerManager`) and
render `[mm:ss] Speaker N: …`, WhisperKit-only, always-on, graceful-degrade to plain. This
doc is everything we consciously deferred.

## What the manual smoke confirmed (2026-07-06)

- **Whisper diarization works end to end**, and — importantly — the diarizer's Core ML models
  (pyannote segmentation + wespeaker) **download and run under App Sandbox** on first diarized
  job. This was the top pre-release unknown from the final review; it's now cleared.
- **Per-turn timestamps** ship (`[mm:ss]`, rolling to `[h:mm:ss]` past an hour).
- **Parakeet (and SenseVoice/Cohere) stay plain** — by design, see §1.

---

## 1. Parakeet / FluidAudio-engine timestamps (enables non-Whisper diarization)

**Why it's plain today.** `transcribeDiarized` calls `engine.transcribeTimed(...)` first; only
`WhisperKitEngine` implements it. `FluidAudioEngine` (Parakeet, SenseVoice, Cohere) inherits the
protocol default that throws `.timestampsUnsupported`, so diarization is skipped and the plain
`transcribe` path runs. That's the intended Phase-A scope, not a bug.

**The data is already there — this is a surfacing job, not new capability.** FluidAudio's
Parakeet ASR result carries token timings we currently discard:

- `Packages/AudioPipeline/.build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift`:
  - `public struct ASRResult { public let text: String; …; public let tokenTimings: [TokenTiming]? }`
  - `public struct TokenTiming { public let token: String; public let tokenId: Int; public let startTime: TimeInterval; public let endTime: TimeInterval; public let confidence: Float }`
- Today `FluidAudioEngine.transcribe` (Parakeet case) returns only `result.text` and throws
  `tokenTimings` away — exactly the shape `WhisperKitEngine` was in before Task 7.

**The work:** implement `transcribeTimed` on `FluidAudioEngine` for the Parakeet case — run the
same `asr.transcribe`, map `result.tokenTimings` → `[TimedWord]`.

**The real caveat (why it's not a 10-minute change): token ≠ word.** Parakeet TDT tokens are
sub-word pieces (e.g. `▁hel`, `lo`). A naive 1-token-1-`TimedWord` mapping would feed the aligner
sub-word fragments. Cosmetically that's mostly harmless for *speaker attribution* (adjacent
fragments almost always fall in the same speaker segment), but the rendered run text needs
fragments joined without spurious spaces. WhisperKit's `WordTiming` is already word-level, which
is why Task 7 was clean. Parakeet needs a **token→word grouping step** — that's the actual work.
Parakeet's transducer timestamps are typically *tighter* than Whisper's, so this is an accuracy
upside, not just parity.

**Other FluidAudio engines:** verify `tokenTimings` is actually populated (it's optional — some
configs return `nil`). **SenseVoice / Cohere** may expose no timings at all (`senseVoice.transcribe`
and `cohere transcribeLong` return only text today) — they'd stay plain regardless, which is fine.

**Scope:** a small standalone feature (one engine method + grouping + tests + a gated E2E). Worth
its own brief when picked up.

---

## 2. Phase C — channel-aware diarization (design exists, plan does not)

The channel-aware approach — diarize `system.flac` for remote speakers, treat `mic.flac` as
**"You"**, attribute against `combined.flac`'s single transcription pass, fall back to Phase-A
blind when the tracks are absent — is **fully designed** in
`docs/superpowers/specs/2026-07-05-local-diarization-design.md` §5, including the open refinement
for a multi-speaker mic track.

**What's missing:** a task-by-task implementation plan (Phase A had one; Phase C does not). Run
the `writing-plans` skill against §5 before implementing. The storage groundwork it depends on
(`mic.flac`/`system.flac`, default on) already shipped in Phase A, so its inputs exist.

---

## 3. Deferred perf / robustness (from final review + bot review)

Ordered by how much they matter before a heavy-use or notarized release:

1. **`performCompleteDiarization` blocks a cooperative thread-pool thread** — ✅ **DONE**
   (commit follows this doc). `FluidAudioDiarizer` now caches the **Sendable** `DiarizerModels`
   and builds + runs + consumes the non-Sendable `DiarizerManager` entirely inside a
   `Task.detached(priority: .utility)`, so the CPU-bound pyannote+wespeaker pipeline no longer runs
   on the actor's executor. Note: the naive "wrap it and capture `m`" from the review does **not**
   compile — `DiarizerManager` is non-Sendable and cannot cross into the detached task; the correct
   pattern caches the Sendable `models` and constructs a fresh manager per call inside the task
   (cheap: `EmbeddingExtractor.init` only stores the already-loaded `MLModel`; the expensive Core ML
   compile stays one-time in `downloadIfNeeded`).

2. **Diarizer is never unloaded.** `LocalTranscriptionService.unloadResident()` frees the resident
   ASR engine but the `FluidAudioDiarizer`'s `DiarizerManager` stays resident once loaded. Measure
   steady-state memory on the 8 GB target (spec §7 open question) and add an unload path if needed.

3. **Diarize + transcribe run sequentially** in `transcribeDiarized` (`transcribeTimed` fully
   awaited before `loadSamples`+`diarize` start). They're independent; `async let` would roughly
   halve cold-start wall time. Pure latency win, no behavior change. *(Note: the `loadSamples`
   resample itself was already moved off the service actor into a detached task in the PR #29
   follow-up fix `0aef327`.)*

4. **Aligner boundary tie-break is untested.** `attributeSpeakers` uses inclusive `[start,end]` on
   both ends; a word midpoint exactly on a shared boundary of two adjacent segments picks
   array-order-first, and the equidistant nearest-fallback tie does the same. Measure-zero with real
   Float timestamps and the choice is reasonable, so latent only — worth one pinning test + a
   one-line comment. `SpeakerAlignment.swift`. (There's also a dead `?? ""` fallback after the
   non-empty guard — harmless, drop when touching the file.)

---

## 4. Diarizer model management UI (spec vs. plan deferral)

Spec §4b asked for the diarizer's model download to "surface in the existing Models flow." Phase A's
plan (Task 8) deliberately scoped it to a **lazy `DiarizerModels.downloadIfNeeded()`** on first
diarized job — no progress UI, no Settings → Models row. The smoke confirmed the download *works*
under sandbox, but there's still **no user-visible progress or management** for it. If diarization
becomes a headline feature, add a Models-flow entry (size, download state, delete) alongside the ASR
models.

---

## 5. Release-notes reminder

Phase A flipped the `keepOriginalCAF` default from `true` to `false`. Existing users who never
toggled it will start having raw `.caf` deleted after conversion post-update. **No recording data is
lost** — `combined.flac` plus the now-default `mic.flac`/`system.flac` are kept — but it's a
behavior change worth a line in release notes. (The PR #29 follow-up `0aef327` also hardened this
path: a failed per-track FLAC export now preserves the source `.caf` rather than deleting it.)
