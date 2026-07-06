# Auto-Dictation (always-on, VAD-gated) — Design

Date: 2026-07-06
Status: Approved (brainstorming), pending spec review
Branch: `worktree-feat-auto-dictation`

## Problem

Today dictation is **manual and one-shot**: the user holds a modifier (push-to-talk)
or taps it to toggle a single capture, the whole utterance records to a WAV, then
transcribes and inserts. The user wants a **hands-free mode**: the mic stays on, and
whenever they speak it transcribes and types into the focused field, so they can talk
continuously (e.g. long sessions dictating to Claude) without touching the keyboard
per utterance.

## Feasibility framing (what's solvable vs. not)

The request splits into two problems with very different answers:

1. **"Is there speech vs. background noise right now?"** — *Solvable and reliable.*
   This is voice activity detection (VAD). A neural VAD rejects fans, keyboard, music,
   and steady noise well.
2. **"Is this speech meant for the app to type?"** — *Not solvable from audio alone.*
   VAD cannot tell dictation from talking to a colleague, a phone call, or a video.

**Design decision (user):** problem 2 is explicitly **out of scope** — it is the
user's responsibility. Auto-dictation is a *mode the user switches on and off*. While
on, any detected speech is transcribed and typed; if the user picks up the phone, they
switch the mode off. Misfires while on are accepted. This is what makes the feature
reliable: we only have to solve problem 1.

## Scope

**In scope**
- An always-on capture + VAD segmentation loop that transcribes each utterance and
  appends it to the focused field.
- Toggled on/off by a **short tap of the existing dictation trigger** (no new hotkey).
- Engine-agnostic: works with any installed local model (WhisperKit, FluidAudio /
  Parakeet, IndicConformer) via the existing local transcription dispatch.
- Local-only (Apple Silicon), consistent with existing local-model gating.

**Out of scope (v1)**
- Intent disambiguation (see above — user's responsibility).
- True streaming ASR / live word-by-word insertion into the target field.
- In-memory audio hand-off to engines (v1 writes a temp WAV per utterance).
- Remote-provider auto mode (auto requires a local model).

## Constraints & non-negotiables

- **Append-only into foreign fields.** Auto mode types into *other apps'* text fields
  (terminal, browser). Into a foreign field the app can only append; it cannot reliably
  revise text it already inserted. Whisper-family engines revise hypotheses as more
  audio arrives, so any live partials can only live in the app's own overlay, never in
  the target field. Utterances are therefore committed **whole, on endpoint**.
- **Engine-agnostic.** Per-utterance transcription must route through the existing
  `BatchTranscriber` → `LocalTranscriptionService` path, which already dispatches to
  WhisperKit / FluidAudio / IndicConformer by model. No engine-specific code in the
  auto loop.
- **Local-only / Apple Silicon.** Reuses the existing `LocalModelSupport` gate. If the
  dictation source is a remote provider or the Mac is Intel, auto mode is unavailable.
- **Mic indicator stays lit** the entire time the loop is on (inherent to always-on
  capture). Acceptable because the user opts in per session.
- **Default MainActor isolation** is on in this project; audio-thread work must be
  explicitly `nonisolated` / off-main (see CLAUDE.md and
  `feedback_mainactor_closure_sendable_audio`).

## Architecture

New pieces, placed to keep clean, independently testable boundaries:

### `ContinuousMicTap` (RecordingCore)
One always-on `AVAudioEngine` mic tap held open while the loop is on. Converts the
input to **16 kHz mono `Float`** frames (reusing the resample path already in
`DictationWAVWriter`) and delivers them to two sinks: the VAD and the segment writer.
Runs off the main actor (`nonisolated` tap closure, `@Sendable`).

### `VoiceActivityDetector` protocol + FluidAudio implementation
- Protocol in `DictationCore` (pure): takes a frame of 16 kHz mono `Float` samples,
  returns a speech/no-speech verdict (or speech probability). Lets tests inject a fake.
- Implementation wraps **FluidAudio's `VadManager` (Silero-class)** and lives in
  `LocalTranscription`, the module that already imports FluidAudio — so RecordingCore /
  DictationCore stay FluidAudio-free and no new dependency is added.

### `AutoDictationSegmenter` (DictationCore, **pure**)
Consumes per-frame speech/no-speech verdicts and produces segment boundary events:
`beginSegment`, `finalizeSegment`. Encapsulates the endpointing policy (pause timeout,
max-cut, min-speech guard, pre-roll). Pure and deterministic → unit-testable with
synthetic verdict streams, no audio.

### `AutoDictationController` (app, alongside `DictationCoordinator`)
Owns the tap, VAD, and segmenter. On each `finalizeSegment`, writes the buffered
utterance to a temp WAV (`DictationTempStore`) and runs it through the existing
`BatchTranscriber` in local shape; on success appends the text via the existing
`TextInserter`. Manages model residency, the re-arming loop, and overlay/menu-bar
state. It exposes a simple `toggle()` / `stop()` surface and does **not** own a hotkey
monitor of its own.

### Trigger ownership (single owner)
`DictationCoordinator` remains the **sole** owner of the `HotkeyTapMonitor` and gesture
interpretation — there is never a second monitor on the trigger. It routes gestures:
- **Tap** (`.toggle`): branch on `settings.dictation.shortTapAction`.
  `oneShot` → existing `machine.startOrToggle()` (one-shot capture, unchanged);
  `autoListening` → `autoController.toggle()`.
- **Hold** (`.pttStart`/`.pttEnd`): existing one-shot PTT path, **suppressed while the
  auto loop is on** (see conflict note).

`AutoDictationController` is thus driven *by* `DictationCoordinator`, not a peer that
competes for the hotkey.

### Reused unchanged
`BatchTranscriber`, `LocalTranscriptionService` (engine dispatch), `TextInserter`,
`DictationTempStore`, `DictationOverlayController`, model-residency helpers
(`ensureLocalModelResident` / `isLocalModelResident`), `LocalModelSupport` gate.

## Data flow

```
mic → ContinuousMicTap → 16kHz mono Float frames ─┬─→ VoiceActivityDetector (FluidAudio Silero) → speech?/frame
                                                  └─→ pre-roll ring buffer + segment writer
                       speech?/frame → AutoDictationSegmenter (pure)
                         → beginSegment:  open temp WAV, flush pre-roll + write live frames
                         → finalizeSegment (pause endpoint OR max-cut): close WAV
                         → BatchTranscriber(local shape, selected model) → text
                         → TextInserter.append into focused field
                         → re-arm, keep listening
```

A **pre-roll buffer** (~300 ms) is held back and prefixed to each segment so VAD onset
latency does not clip the first word.

## Interaction model (reuse existing trigger; no new hotkey)

A new persistent setting decides **what a short tap does**. Hold/PTT is never touched.

| Gesture | Short-tap action = **One-shot** (today's default) | Short-tap action = **Auto-listening** |
|---|---|---|
| **Short tap** | start / stop a single capture *(unchanged)* | **toggle the always-on auto loop on ↔ off** |
| **Hold (PTT)** | push-to-talk one-shot *(unchanged)* | push-to-talk one-shot, unchanged (see conflict note) |
| **Foreign key mid-press** | cancel *(unchanged)* | cancel |

Two levels:
- **Setting** (`DictationSettings`, persistent): *short-tap action* =
  `oneShot` \| `autoListening`. This is the user's earlier "if the user chooses auto
  dictation."
- **Runtime**: when the action is `autoListening`, each tap flips the continuous loop
  between *listening* and *off*.

PTT hold keeps working as-is regardless of the setting — even with `autoListening`
selected, a deliberate hold still gives a one-shot capture.

**Conflict note:** while the auto loop is *on* (mic already capturing continuously,
whether armed or mid-segment), a PTT hold would double-capture. Resolution: **a hold is
ignored the whole time the auto loop is on** (the loop already captures everything);
PTT holds behave normally whenever the loop is off.

## State machine (re-arming loop)

Auto mode is a re-arming loop distinct from the existing one-shot
`DictationStateMachine`:

```
off ──(tap toggles on)──▶ armedListening
armedListening ──(speech onset)──▶ capturing
capturing ──(pause endpoint | max-cut)──▶ transcribing
transcribing ──(text ready)──▶ appending ──▶ armedListening
transcribing ──(empty/failed)──▶ armedListening
any ──(tap toggles off)──▶ off
```

- **Serialized transcription, overlapped capture.** Transcription runs serialized so
  utterances append in spoken order, but capture of utterance N+1 may begin while N is
  still transcribing (no dropped speech). A small ordered queue holds pending segments.
- The pure `AutoDictationSegmenter` owns onset/endpoint/max-cut decisions; the
  controller owns the transcribe→append side effects and the on/off gate.

## VAD & segmentation defaults

- **VAD:** FluidAudio `VadManager` (Silero-class neural). This is the "background noise
  recognised and filtered out" requirement.
- **Endpoint pause:** ~600 ms of silence finalizes an utterance.
- **Max-cut:** ~15 s force-flush at the nearest micro-pause, so long monologues keep
  flowing instead of holding all text until the user finally pauses.
- **Min-speech guard:** ~250 ms minimum speech before a segment is committed, so a
  cough/click does not fire a segment.
- **Pre-roll:** ~300 ms.

These are internal defaults for v1 (not user-exposed). They may become settings later
if tuning proves necessary.

## Model residency

On toggle-on, preload the selected local model once (via existing
`ensureLocalModelResident`) and keep it resident for the whole session so each
utterance does not reload the model. Unload (or leave to existing eviction) on
toggle-off.

## Feedback / UI

- **Menu-bar state:** a distinct indicator while the auto loop is on (reuses the
  existing dictation menu-bar label surface).
- **Overlay:** reuse `DictationOverlayController` to show loop state
  (listening / transcribing). Live partials, if shown at all, stay in the overlay only.

## Settings changes

`DictationSettings` gains a short-tap action field, e.g.:

```swift
enum ShortTapAction: String, Codable, Sendable { case oneShot, autoListening }
var shortTapAction: ShortTapAction = .oneShot   // default preserves today's behavior
```

Tolerant decode (like the existing `streamLive` / `language` handling) so pre-existing
persisted blobs default to `.oneShot`.

## Error handling

- **No local model installed / remote source / Intel:** tap toggle is unavailable with
  a hint (reuses existing gating messaging).
- **A segment transcription fails:** log it, flash the overlay, keep the loop armed
  (do not tear the whole mode down on one bad utterance).
- **Mic unavailable on toggle-on:** flash "Mic unavailable", return to off (mirrors the
  existing `beginCapture` failure path).
- **Empty transcript for a segment:** silently re-arm (no insert, no error).

## Testing

- **`AutoDictationSegmenter` (pure, Swift Testing, autonomous):** feed synthetic
  speech/silence verdict streams; assert segment boundaries, pause endpoint, max-cut,
  min-speech guard, pre-roll inclusion.
- **`VoiceActivityDetector` fake:** drive the controller loop deterministically without
  real audio or a model.
- **State machine tests:** on/off toggling, serialized-append ordering, failure keeps
  loop armed.
- **App-hosted integration smoke** (real mic + model) behind the existing gated-test
  pattern (skips when unavailable), similar to `IndicConformerIntegrationTests`.
- After SPM tests pass, **rebuild the app target** to confirm it still compiles
  (per CLAUDE.md).

## Open questions / deferred

- In-memory (`[Float]`) hand-off to engines instead of temp WAV per segment — a latency
  optimization deferred past v1.
- Making endpoint/max-cut/min-speech thresholds user-settable — deferred until tuning
  shows it is needed.
- True streaming ASR with live in-field updates — explicitly not v1 ("I don't need
  streaming yet").
```
