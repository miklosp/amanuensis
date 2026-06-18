# Dictation — design

**Date:** 2026-06-18
**Status:** Approved (brainstorming)
**Scope:** M4 dictation — v1 (batch transcription). Streaming and local-MLX
transcription are explicitly out of scope; the design reserves their seams.

## Goal

Global push-to-talk / toggle dictation: press a configurable trigger, speak,
and have the transcribed text inserted at the cursor (clipboard fallback when
insertion is unavailable). A short audio clip is captured to a temp file,
uploaded to a cloud STT provider (default Groq Whisper turbo, reusing the
existing `Provider`/`Keychain` plumbing), and the result is pasted via a
synthetic ⌘V. The menu-bar icon reflects dictation state with an animated
waveform; an optional subtle bottom-center overlay can be enabled.

The feature stays **fully within App Sandbox** and keeps Mac App Store
distribution open (see Decisions / Permissions).

Out of scope for v1: real-time streaming transcription, on-device MLX
transcription, LLM cleanup of transcripts, persisting dictation audio into the
Recordings library, multiple/independent key bindings, custom vocabulary. The
`DictationTranscriber` protocol is the seam where streaming and MLX engines
plug in later.

## Current state

- `AppCoordinator` (`Amanuensis/AppCoordinator.swift`) is the `@MainActor
  @Observable` composition root; it already owns the recording lifecycle,
  job execution, the mic-in-use cue, and the `KeychainStore`/`providers`/`jobs`
  stores. New subsystems hang off it the same way `MicCueController` does.
- Persistent menu-bar `.accessory` app: `MenuBarExtra` (`.menu` style) in
  `Amanuensis/AmanuensisApp.swift`, icon driven by `coordinator.isRecording`
  (`Image(systemName:)`, no animation yet). `AppDelegate.swift` keeps the app
  alive with no windows.
- Mic capture: `MicRecorder`
  (`Packages/AudioPipeline/Sources/RecordingCore/MicRecorder.swift`) taps
  `AVAudioEngine` input and writes via `AudioFileWriter`; the tap closure is
  `@Sendable nonisolated` (the documented audio-thread rule —
  `feedback_mainactor_closure_sendable_audio` memory). `CombinedFLACExporter`
  does a *post-stop* mix/downsample/encode — the latency we deliberately avoid
  for dictation.
- Transcription: `JobRunner`
  (`Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`)
  dispatches by `JobShape` to handlers conforming to `AudioJobSending`
  (`func send(job:provider:audioURL:apiKey:) async throws -> String`). Handlers
  are batch (upload whole file, await one string); **no streaming exists**.
  `Provider` carries `baseURL` + `apiKeyRef`; secrets live in `KeychainStore`
  (actor). Groq uses the `transcriptionMultipart` shape.
- Settings: `AppSettings`
  (`Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`) is an
  `@Observable` UserDefaults prefs object; `SettingsView`
  (`Amanuensis/UI/SettingsView.swift`) renders a grouped `Form`.
- Floating-panel precedent: `MicCueController` + `MicCueView`
  (`Amanuensis/UI/`) own a non-activating `NSPanel` — the model for the overlay.
- Pure-policy precedent: `MicCuePolicy`
  (`Packages/AudioPipeline/Sources/RecordingCore/`) — a unit-tested state
  struct with effects performed outside it. Dictation mirrors this split.
- The SPM-architecture spec (`2026-05-24-spm-module-architecture-design.md` §8)
  reserved an M4 dictation seam under the placeholder name `DictationKit` and a
  separately-codesigned MLX satellite. **This spec supersedes that name**
  (`DictationCore`, to match `RecordingCore`) and keeps the local-MLX satellite
  deferred — only the `DictationTranscriber` seam is created now.

## Decisions

- **D1 — Hotkey via `CGEventTap(.listenOnly)`, not `NSEvent` global monitor.**
  Apple DTS (Forums thread 789896, 707680): the `NSEvent` global monitor needs
  the *Accessibility* privilege (blocked under App Sandbox), whereas a
  `CGEventTap` needs only *Input Monitoring*, which is available to sandboxed
  and Mac-App-Store apps. The tap is `listenOnly` — it observes, never consumes,
  so normal ⌘ shortcuts always pass through.
- **D2 — Left/right ⌘ via device-dependent flag bits.** `flagsChanged` events
  carry the modifier keycode (left ⌘ = `0x37`/55, right ⌘ = `0x36`/54) and the
  raw `CGEventFlags` device bits (`NX_DEVICELCMDKEYMASK` = `0x08`,
  `NX_DEVICERCMDKEYMASK` = `0x10`). We read those bits to know *which side* and
  whether it went *down* or *up*. Default trigger: **right ⌘** (left ⌘ left free
  for muscle-memory shortcuts).
- **D3 — One trigger, tap = toggle / hold = PTT.** Key-down starts a hold timer.
  Key-up **before** the threshold = a tap (toggles capture on, or off if already
  capturing). Threshold elapsing while still down = a hold → PTT starts now and
  stops on key-up. Default threshold **250 ms**, configurable.
- **D4 — Solo-gesture guard.** The recognizer only fires for a *clean* ⌘ press:
  if any other key or modifier is pressed between ⌘-down and ⌘-up, the gesture
  is cancelled (it was a real shortcut like ⌘C). This is what makes binding a
  bare modifier safe.
- **D5 — Auto-insert via pasteboard + synthetic ⌘V (`CGEvent.post`), not
  `AXUIElement`.** Per Apple DTS (thread 789896), `CGEvent.post` uses the
  **Post Event** privilege (`CGRequest/PreflightPostEventAccess`), which is
  *App-Sandbox-compatible* (it shows in System Settings under Accessibility but
  is limited to posting events). `AXUIElement` text injection needs *full*
  Accessibility, which the sandbox blocks — so we do not use it. Insert =
  save pasteboard → set string → post ⌘V → restore pasteboard after a short
  delay.
- **D6 — Clipboard fallback.** If Post Event access is absent (or the user
  picks clipboard-only mode), the text is left on the clipboard with a
  "copied — press ⌘V" cue. This is req #4's degraded path and also the natural
  fallback if App Review ever objects under Guideline 2.4.5 — same binary, no
  sandbox change.
- **D7 — Capture straight to a temp 16 kHz mono WAV; no post-stop transcode.**
  Downsample to 16 kHz mono happens *in the tap* (concurrent with speech), and
  the WAV (a Groq-accepted, header-finalize-only format) is closed on stop and
  uploaded immediately. FLAC/`CombinedFLACExporter` is **not** used — dictation
  audio is ephemeral, so lossless/compression buys nothing and only adds
  latency. Whisper resamples to 16 kHz internally, so 16 kHz mono is no quality
  loss for STT.
- **D8 — Temp-file lifecycle.** Captures go to a dedicated
  `FileManager.temporaryDirectory/Dictation/` subfolder with **unique names**
  (`dictation-<UUID>.wav`). Each file is deleted as soon as its upload resolves
  (success, failure, or cancel) via guaranteed cleanup. On app launch the folder
  is **swept** wholesale (nothing is legitimately in flight at launch) to
  reclaim crash/force-quit orphans. The sweep touches *only* this temp folder —
  never the opt-in "keep audio" artifact (D9).
- **D9 — CAF "keep audio" is opt-in and off by default.** Dictation persists no
  audio by default. A Settings toggle can write a kept copy to a real location
  (not the temp sweep dir) for users who want the raw audio for non-STT use.
- **D10 — Pure logic in `DictationCore`; effectful edges + UI app-side.** Mirror
  the `MicCuePolicy` split: deterministic, unit-tested types in the SPM package
  (Foundation-only, no AppKit/Jobs deps); the event tap, paste, overlay, menu
  bar, and the Jobs-coupled `BatchTranscriber` live app-side.
- **D11 — Default backend Groq Whisper turbo, reusing existing `Provider`s.**
  Dictation does **not** create a `Job`; it references a selected `Provider.id`
  + model (default `whisper-large-v3-turbo`) and calls the existing
  `AudioJobSending` handler directly to get the transcript string. Any
  configured provider can be selected.
- **D12 — Menu-bar animation: SF Symbol effect first.** Animate a `waveform`
  symbol with `.symbolEffect(.variableColor)` (amplitude-nudged by a mic level
  meter) while dictating; the current static icons stay for idle/recording.
  Escalation to an `NSStatusItem` + custom AppKit view (true level-driven
  waveform) is noted but deferred — try the simpler path first.

## Components

### `DictationCore` — new SPM package (Foundation-only, `nonisolated` default)

`Packages/AudioPipeline/Sources/DictationCore/`. Pure, unit-tested. No AppKit,
no `AudioPipelineJobs` dependency.

- **`TriggerSide`** — `enum { leftCommand, rightCommand }`, maps to keycodes
  54/55 and the device flag bits.
- **`ModifierGestureRecognizer`** — pure struct. Input: `keyChanged(side:
  TriggerSide, isDown: Bool, at: TimeInterval)` and `otherKeyPressed` /
  `otherModifierChanged` (for the solo guard). Output actions: `.none`,
  `.startHoldTimer`, `.toggle`, `.pttStart`, `.pttEnd`, `.cancel`. Owns the
  configured trigger side + hold threshold. `holdTimerElapsed(at:)` resolves the
  tap-vs-hold branch. Fully deterministic — no timers/IO inside (the coordinator
  owns the actual timer).
- **`DictationStateMachine`** — pure struct. Phases `idle → listening →
  transcribing → inserting → idle` plus `error`. Events: `.start` (from
  `.toggle`/`.pttStart`), `.stop` (from second `.toggle`/`.pttEnd`),
  `.transcriptReady(String)`, `.failed(DictationError)`, `.empty`. Actions:
  `.beginCapture`, `.endCaptureAndTranscribe`, `.insert(String)`,
  `.showError(...)`, `.none`. A trigger arriving mid-`transcribing`/`inserting`
  is ignored (re-entrancy guard); a trigger while `listening` stops. Mixed case
  (toggled on, then a hold) → `.stop`, the trailing release is a no-op.
- **`DictationTranscriber`** — the streaming seam:

  ```swift
  public protocol DictationTranscriber: Sendable {
      func transcribe(audioFile: URL,
                      onPartial: @Sendable (String) -> Void,
                      onFinal: @Sendable (String) -> Void) async throws
  }
  ```

  Batch impls ignore `onPartial` and call `onFinal` once. (The streaming
  milestone may generalize the input from a file URL to a live PCM source; that
  generalization is deferred, not pre-built.)
- **`DictationSettings`** — `Codable` value type: `enabled`, `trigger:
  TriggerSide`, `holdThresholdMs`, `providerID: UUID?`, `model: String`,
  `insertMode: { autoInsert, clipboardOnly }`, `showOverlay: Bool`, `keepAudio:
  Bool`. Persisted as one JSON key by `AppSettings` (the field count justifies a
  nested value over flat vars).

Package isolation: `nonisolatedSettings` (matches `AudioPipelineJobs`). Added to
`Package.swift` as a library product + target + `DictationCoreTests` test target.

### `BatchTranscriber` — new, app-side (`Amanuensis/Dictation/`)

Conforms to `DictationTranscriber`; depends on `AudioPipelineJobs`. Given the
selected `Provider` (by id) and its `Preset` shape:

1. Resolve the handler for the shape (reuse `JobRunner`'s shape→handler
   dispatch; extract a `handler(for: JobShape)` factory if not already
   reachable).
2. Fetch the API key from `KeychainStore` via `Provider.apiKeyRef`.
3. Build a **transient** `Job` (model from settings, default/empty fields, no
   output path — dictation never writes a job output file).
4. `try await handler.send(job:provider:audioURL:apiKey:)` → transcript string →
   `onFinal`.

No changes to existing handler wire code.

### `HotkeyTapMonitor` — new, app-side (`Amanuensis/Dictation/`)

`@MainActor`. Owns the `CGEventTap` (`.listenOnly`, `.cgSessionEventTap`,
`flagsChanged` + `keyDown` of interest), its run-loop source, and the Input
Monitoring permission (`CGPreflightListenEventAccess` /
`CGRequestListenEventAccess`). Translates each event into the recognizer's
inputs (decoding side/up-down from device flag bits per D2; feeding
`otherKeyPressed` for the solo guard) and forwards recognizer actions to the
coordinator. Enable/disable starts/stops the tap.

### `TextInserter` — new, app-side (`Amanuensis/Dictation/`)

`@MainActor`. Owns Post Event access (`CGPreflight/RequestPostEventAccess`).
`insert(_ text:)`: if access granted and mode is `autoInsert` → snapshot
`NSPasteboard.general`, set the string, post a synthetic ⌘V
(`CGEvent` key-down/up of `v` with `.maskCommand`), then restore the prior
pasteboard contents after a short delay. Otherwise → leave text on the
pasteboard and return `.clipboardFallback` so the coordinator shows the
"press ⌘V" cue.

### `DictationCoordinator` — new, app-side (`Amanuensis/Dictation/`)

`@MainActor`. Wires the feature and owns the timers/effects (the `MicCuePolicy`
→ `AppCoordinator.apply(...)` pattern):

- Owns `ModifierGestureRecognizer`, `DictationStateMachine`, `HotkeyTapMonitor`,
  `TextInserter`, a `BatchTranscriber`, the temp-file manager, and a mic level
  meter.
- Recognizer `.startHoldTimer` → a `Task.sleep(holdThresholdMs)` that feeds
  `holdTimerElapsed`. `.toggle`/`.pttStart`/`.pttEnd` → state-machine events.
- `.beginCapture` → start `MicRecorder` writing a 16 kHz mono WAV to a fresh
  temp URL; start level metering (feeds menu bar + overlay). `.endCaptureAndTranscribe`
  → stop recorder, close file, `await transcriber.transcribe(...)`. `.insert` →
  `TextInserter`, then delete the temp file (guaranteed cleanup). `.showError` →
  overlay/notification + Logs.
- Exposes observable `state` for the menu bar + overlay. Hangs off
  `AppCoordinator` (constructed in `init`, gated by `settings.dictation.enabled`).
- On launch: sweep the `Dictation/` temp dir.

### `DictationOverlayController` + `DictationOverlayView` — new, app-side

`Amanuensis/UI/`. Same non-activating `NSPanel` recipe as `MicCueController`,
positioned **bottom-center**. Shows listening (animated waveform + live level),
transcribing (spinner), inserted (brief ✓), error. Created only when
`showOverlay` is on (default off).

### Menu bar — modify `AmanuensisApp.swift` (+ new `MenuBarIconView`)

State-driven `MenuBarExtra` label: idle → existing `waveform.circle`; meeting
recording → `record.circle.fill`; **dictating** → `waveform` with
`.symbolEffect(.variableColor)` modulated by the mic level. (NSStatusItem
escalation deferred, D12.)

### `AppSettings` — modify

Add a `dictation: DictationSettings` value persisted as a single JSON
UserDefaults key (new `Keys` entry), with sensible defaults (enabled off until
the user opts in, trigger right ⌘, threshold 250 ms, model
`whisper-large-v3-turbo`, `autoInsert`, overlay off, keepAudio off). A `didSet`
re-serializes and notifies the coordinator to start/stop the tap.

### `SettingsView` — modify

New `Section("Dictation")`: enable toggle; trigger picker (Right ⌘ / Left ⌘);
hold threshold; provider picker (over configured `Provider`s) + model field;
insert mode (Auto-insert / Clipboard only); show-overlay toggle; keep-audio
toggle; and **inline permission status + grant buttons** for Input Monitoring
and Post Event access.

## Data flow

```
CGEventTap (.listenOnly, flagsChanged/keyDown)  ──► HotkeyTapMonitor
        │  decode side + up/down from device flag bits; solo guard
        ▼
ModifierGestureRecognizer  ──► .startHoldTimer / .toggle / .pttStart / .pttEnd
        │
        ▼  DictationCoordinator
DictationStateMachine
   .start ──► .beginCapture ──► MicRecorder → 16kHz mono WAV (temp/Dictation/<uuid>.wav)
                                        │  (level meter → menu bar + overlay)
   .stop  ──► .endCaptureAndTranscribe ─┘
        │            close file
        ▼
BatchTranscriber.transcribe(audioFile:)  ── resolve Provider+shape, Keychain key,
        │                                     transient Job → AudioJobSending.send → text
        ▼  onFinal(text)
DictationStateMachine .transcriptReady ──► .insert(text)
        │
        ▼
TextInserter ── Post Event access? ── yes ─► pasteboard + synthetic ⌘V (restore after)
        │                            └─ no ─► clipboard + "press ⌘V" cue
        ▼
delete temp WAV (guaranteed)  ──► idle
```

PTT and toggle differ only in how `.start`/`.stop` are produced (release-timed
hold vs. discrete taps); everything downstream is identical.

## Permissions

All three are runtime TCC grants, **App-Sandbox-compatible — no new
entitlement** expected (flagged for verification, as the mic-cue spec did):

- **Microphone** — already held by the recording path.
- **Input Monitoring** — for the hotkey tap (`CGRequestListenEventAccess`).
- **Post Event access** — for auto-insert (`CGRequestPostEventAccess`); absence
  degrades to clipboard-only, the feature still works.

Enable flow: turning dictation on preflights both privileges and surfaces an
inline prompt + grant button per missing one. Posting events requires a native
main executable (we are native Swift — fine).

## Error handling

- Input Monitoring denied → tap inert; Settings shows status + grant button;
  no trigger fires. Recording/menu unaffected.
- Post Event denied → `TextInserter` returns `.clipboardFallback`; text on
  clipboard + cue. No error surface beyond the cue.
- No provider selected → trigger disabled; Settings points to provider setup.
- Transcription failure (network/timeout/HTTP) → surfaced via the existing Jobs
  error path + `AppLog`/Logs (handler errors are already `LocalizedError` —
  `project_job_failures_hidden_behind_generic_error` memory), plus a brief
  overlay/notification. Temp file still deleted.
- Empty transcript → `.empty` → no insert, brief "nothing heard" cue.
- Mic permission denied → reuse the existing permission path; abort capture.

## Tests

- **SPM `DictationCoreTests` (new) — the heart of the feature:**
  - `ModifierGestureRecognizer`: tap below threshold → `.toggle`; still-down at
    threshold → `.pttStart`, release → `.pttEnd`; left vs right side selection
    (wrong side ignored); solo guard — another key or modifier during the press
    → `.cancel`; rapid second tap toggles off.
  - `DictationStateMachine`: full idle→listening→transcribing→inserting→idle for
    both toggle and PTT; trigger while `listening` stops; trigger while
    `transcribing`/`inserting` ignored; `.failed` and `.empty` paths;
    mixed toggle-then-hold → stop.
  - `DictationSettings`: JSON round-trip, defaults.
- **SPM `AppSettingsTests`:** `dictation` defaults correct and round-trips
  through UserDefaults.
- **App-hosted XCTest** (`AmanuensisTests`, needs real tap/`NSApp`/permissions):
  `HotkeyTapMonitor` produces gestures from real ⌘ taps/holds; `TextInserter`
  pastes into a focused field and restores the pasteboard; preflight reflects
  granted/denied; `BatchTranscriber` against a stub `AudioJobSending` returns the
  string and builds a valid transient `Job`.
- Per CLAUDE.md: after the SPM suite is green, rebuild the app target via the
  xcode-build daemon to confirm the app still compiles.

## Out of scope (deferred)

- Real-time streaming transcription (websocket transport + partial results +
  live overlay text). Seam: `DictationTranscriber.onPartial`. Deepgram/Soniox
  are the likely first streaming providers (Deepgram keeps provider continuity).
- On-device MLX transcription. Seam: a future `MLXTranscriber: DictationTranscriber`,
  as the satellite bundle reserved in `2026-05-24-spm-module-architecture-design.md`
  §8/D7 — name and packaging settled at that milestone.
- LLM cleanup/formatting of transcripts; custom vocabulary/prompts.
- Persisting dictation audio into the Recordings library (only the opt-in
  raw-copy of D9, which is not a library entry).
- Multiple/independent key bindings; chord triggers; non-⌘ triggers.
- Reworking the recording pipeline's STT artifact (FLAC stays; unifying formats
  is a separate change, and WAV would worsen the Groq 25 MB cap on long
  recordings).
- `NSStatusItem` migration for a fully custom animated menu-bar waveform (D12
  escalation).
