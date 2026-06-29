# Mic-off cue — design

**Date:** 2026-06-29
**Status:** Approved for planning
**Branch:** `feat/mic-off-cue` (nested worktree at `.worktrees/mic-off-cue`, based on `main`)

## Goal

While Amanuensis is recording, when the app that *was* using the microphone (a
likely meeting) releases it, show a floating cue offering to **stop recording**.

This mirrors the existing mic-**on** cue ("offer to record when the mic is in
use"), but inverted: gated on *recording* instead of *idle*, and triggered on
the *fall* of external mic use instead of its rise.

## Background: why this is NOT a symmetric copy of the on-cue

The on-cue is driven by `MicActivityMonitor`, which watches
`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device. That
is a **device-level** flag — true if *any* process holds the mic. It works for
the on-cue because Amanuensis is idle (not holding the mic) when a meeting app
grabs it.

The off-cue cannot reuse that signal. The moment Amanuensis records,
`MicRecorder` opens the mic via `AVAudioEngine` (`RecordingSession.start()` →
`mic.start()`), so `IsRunningSomewhere` stays **true for the entire recording**
regardless of what the meeting app does — it only falls to false *after we
stop*, which is too late to offer "want to stop?". A literally-symmetric
implementation would never fire.

To detect "the meeting ended while we keep recording" we need **per-process**
input detection: enumerate audio processes, check each one's input state,
**exclude our own PID**, and react when *no other process* is using the mic.
That API (`kAudioHardwarePropertyProcessObjectList`,
`kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyPID`) is macOS
14.4+ and available at our macOS 26.3 target.

## Decisions (from brainstorming)

1. **Detection:** per-process input detection, excluding our own PID. (The only
   mechanism that works while we hold the mic.)
2. **Scope:** *any* recording. The transition logic (fire on a true→false edge
   of "another app is using the mic") naturally restricts firing to genuine
   "meeting ended" moments — a manual recording with no other app on the mic
   never sees the edge, so it never nags. No need to track how the recording
   started.
3. **Setting:** a *separate* toggle, default on, independent of the on-cue
   toggle.
4. **Monitoring mechanism:** poll (not per-process listeners) while recording.
   Rationale below.
5. **Unification (added during review):** fold the per-process exclusion into
   the on-cue too, deleting the on-cue's `dictation.phase == .idle` guard.
   Rationale below.

## Components

### 1. `OtherInputActivityMonitor` (new — `RecordingCore`)

`@MainActor` type that answers one question: **"is any process other than us
currently capturing the mic?"** Mirrors `MicActivityMonitor`'s public shape
(`start(onChange:)` / `stop()`, idempotent).

- **Stateless probe (shared):**
  `nonisolated static func othersUsingMic(excludingPID pid: pid_t = getpid()) -> Bool`.
  Reads `kAudioHardwarePropertyProcessObjectList` from the system object; for
  each process object reads `kAudioProcessPropertyPID` and
  `kAudioProcessPropertyIsRunningInput`; returns `true` iff some process with
  `pid != excludingPID` has `IsRunningInput == true`. Excluding our own PID is
  what makes the signal meaningful while we ourselves hold the mic, and it also
  excludes our dictation path (same process).
- **Instance (poll loop):** `start(onChange:)` spins a `@MainActor` timer task
  (interval ~1.5 s) that calls the probe and invokes `onChange(Bool)` only when
  the value changes, plus one **baseline** report on start (matching
  `MicActivityMonitor`, so the decision core can treat the first report as a
  non-edge). `stop()` cancels the task. The monitor runs **only while
  recording** — a bounded, user-initiated window.

**Why poll, not per-process listeners.** A listener approach must add/remove a
`kAudioProcessPropertyIsRunningInput` listener per process as processes come and
go — N changing listeners with fragile lifecycle. Polling is a handful of cheap
`AudioObjectGetPropertyData` calls; ~1.5 s latency is irrelevant for a "meeting
ended" nudge; and it only runs during recording. Simpler and robust.

### 2. `MicOffCuePolicy` (new, pure — `RecordingCore`)

A pure decision state machine, structurally a mirror of `MicCuePolicy` with the
*polarity* (trigger on fall, not rise) and the *gate* (recording, not idle)
swapped. Holds no timers, performs no IO; the coordinator feeds events and
executes the returned `Action`.

- `Action`: `.none | .startDebounce | .showCue | .hideCue` (identical to
  `MicCuePolicy.Action`).
- State: `enabled: Bool`, `recording: Bool` (the gate), `othersUsingMic: Bool?`
  (nil until first report = baseline), `phase ∈ {idle, armed, shown, consumed}`.
- Events:
  - `enabledChanged(Bool)` — disabling resets phase and hides any visible cue
    (mirror of on-cue).
  - `recordingChanged(isRecording: Bool)` — sets the gate. On `false` (recording
    over): reset `phase = .idle`, `othersUsingMic = nil` (re-baseline for the
    next session), and hide if shown. On `true`: just set the gate (an edge is
    still required to arm).
  - `othersUsingMicChanged(Bool)` — the core trigger:
    - rising (others → true): a (new) external mic session began → reset
      `phase = .idle` (re-arm path) and hide if a cue was showing (meeting
      resumed). This is the mirror of the on-cue's "mic fell" re-arm.
    - first report / dedup: baseline (`nil`) and no-change → `.none`.
    - falling (others true → false) while `enabled && recording && phase==idle`
      → `phase = .armed`, `.startDebounce`. Otherwise `phase = .consumed`.
  - `debounceElapsed()` — if `phase==armed && enabled && recording &&
    othersUsingMic==false` → `phase = .shown`, `.showCue`; else `.consumed`.
  - `cueDismissed()` — if shown → `.consumed`, `.none`.
- Guarantee: fires at most once per "others-on-mic session" (same anti-nag
  property as the on-cue). After dismiss/auto-dismiss it will not re-fire until
  another app grabs *and then releases* the mic again.

### 3. UI

- **`MicOffCueView` (new — `Amanuensis/UI`):** mirrors `MicCueView` — glass
  capsule, hover close-badge, top-right placement — but with a red **`stop.fill`**
  tile and the copy **"Meeting ended"** / **"Stop recording"**. The action wires
  to stopping the recording.
- **Generalize `MicCueController` into a reusable floating-panel controller.**
  Today it is ~entirely generic `NSPanel` boilerplate (non-activating floating
  panel, top-right positioning, fade in/out, 8 s auto-dismiss) with `MicCueView`
  hardcoded in `show()`. Generalize it to host an injected SwiftUI view, and use
  a single shared instance for both cues. The on-cue and off-cue are mutually
  exclusive in time (idle vs recording), so one instance also guarantees only
  one panel is ever visible. The on-cue call site updates to pass its view;
  on-cue behavior is unchanged. (Alternative considered: a separate
  `MicOffCueController` duplicating ~80 lines of boilerplate and touching no
  on-cue code — rejected in favor of the small shared-controller refactor.)

### 4. Settings

- New `AppSettings.suggestStoppingWhenMeetingEnds: Bool`, default `true`,
  persisted under its own UserDefaults key (mirrors
  `suggestRecordingWhenMicInUse`).
- Second `Toggle` in `SettingsView`'s existing **"Meetings"** section:
  **"Offer to stop recording when the meeting ends"** with a one-line caption,
  `.onChange` → `coordinator.setMicOffCueEnabled(_:)`.

### 5. `AppCoordinator` wiring

- Add members parallel to the on-cue's: `otherInputMonitor`,
  `micOffCuePolicy`, the shared cue controller, an off-cue debounce task, and a
  `lastReportedRecording` flag.
- **Lifecycle:** extend `notifyRecordingActivity()` (already called on every
  recorder transition, including early-return defers) to also drive the off-cue:
  when `status == .recording` flips, feed
  `micOffCuePolicy.recordingChanged(isRecording:)` and **start the
  `OtherInputActivityMonitor` on enter / stop it on leave** (only if the feature
  is enabled). The on-cue's existing idle-flip handling is untouched; the
  off-cue tracking uses its own `lastReportedRecording` guard because
  `.starting → .recording` is not an idle flip.
- `apply(_ action: MicOffCuePolicy.Action)` mirrors the on-cue's `apply`:
  `.startDebounce` → 1.5 s task → `debounceElapsed`; `.showCue` → controller
  shows `MicOffCueView` with action = stop recording, dismiss = feed
  `cueDismissed`; `.hideCue` → cancel debounce + hide.
- `setMicOffCueEnabled(_:)` mirrors `setMicCueEnabled`: toggle policy enabled;
  on disable stop monitor + hide; on enable while recording start monitor.
- Init: seed `micOffCuePolicy.enabledChanged(settings.suggestStoppingWhenMeetingEnds)`.

### 6. On-cue simplification (delete the dictation guard)

Replace the device-level bool fed to the on-cue policy with the per-process
signal, and remove the `dictation.phase == .idle` guard:

```swift
private func handleMicRunning(_ deviceRunning: Bool) {
    // A process OTHER than us is using the mic — exclude our own PID so our
    // dictation/recording never arms the cue. (Replaces the old
    // `dictation.phase == .idle` guard.)
    let others = deviceRunning && OtherInputActivityMonitor.othersUsingMic()
    apply(micCuePolicy.micRunningChanged(others))
}
```

`MicActivityMonitor` (device-level listener) stays as the cheap, event-driven
edge trigger — no idle polling. `MicCuePolicy` and `MicCuePolicyTests` are
unchanged (the policy still receives a `Bool`; only its meaning shifts from
"device running" to "another app running input").

**Behavioral nuance (no regression):** if our own dictation/recording holds the
mic and a meeting joins *mid-hold*, the device flag was already true, so no new
device edge fires and the on-cue will not arm for that meeting. This matches
today's behavior — the `dictation.phase == .idle` guard already suppressed that
exact window.

## Error handling

- Probe: any `AudioObjectGetPropertyData` failure → treat that process as
  not-capturing (`status != noErr ⇒ false`), consistent with
  `MicActivityMonitor`. If the whole enumeration fails, the probe returns
  `false`; the monitor reports only on change, so a transient failure cannot
  spuriously fire the cue (it could at worst momentarily read "no others",
  which the 1.5 s debounce absorbs). No throws cross the boundary.
- `MicOffCuePolicy` is total — every event returns an `Action`; no error states.

## Testing

- **TDD core — `MicOffCuePolicyTests` (Swift Testing, SPM, autonomous):** a full
  mirror of `MicCuePolicyTests`, covering: baseline first-report no-fire;
  falling-edge-arms-then-shows; rising-edge re-arm; fire-once-per-session
  (dismiss then others stays false → no re-show); gated when not recording;
  debounce abort when recording stops mid-debounce; disable-while-shown hides;
  enabling does not retro-arm; `recordingChanged(false)` re-baselines. Runs
  in-sandbox via `swift test --disable-sandbox --package-path
  Packages/AudioPipeline`.
- **`OtherInputActivityMonitor`:** CoreAudio IO — not unit-tested (same as
  `MicActivityMonitor`); validated by a manual run and, where the build daemon
  is available, an app-hosted smoke test.
- **App target build / app-hosted tests:** the Hammerspoon build-helper scripts
  referenced in `CLAUDE.local.md` are absent in the current environment, so the
  app build and `AmanuensisTests` cannot run here. Verification covers the SPM
  policy suite; the app-target build is flagged as needing the user's machine.

## Files

**New (in worktree):**
- `Packages/AudioPipeline/Sources/RecordingCore/OtherInputActivityMonitor.swift`
- `Packages/AudioPipeline/Sources/RecordingCore/MicOffCuePolicy.swift`
- `Packages/AudioPipeline/Tests/RecordingCoreTests/MicOffCuePolicyTests.swift`
- `Amanuensis/UI/MicOffCueView.swift`

**Edited:**
- `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` (new toggle)
- `Amanuensis/UI/SettingsView.swift` (second toggle in "Meetings")
- `Amanuensis/AppCoordinator.swift` (wiring + on-cue guard removal)
- `Amanuensis/UI/MicCueController.swift` (generalize into shared panel controller)

## Out of scope

- Detecting meetings on a non-default input device (same limitation as the
  on-cue).
- Per-process listeners / event-driven off-cue (polling chosen for simplicity).
- Auto-stopping without confirmation (always a cue, never automatic).
