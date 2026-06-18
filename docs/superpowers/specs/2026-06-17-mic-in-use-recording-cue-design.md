# Mic-in-use recording cue — design

**Date:** 2026-06-17
**Status:** Approved (brainstorming)
**Scope:** Auto-detect ongoing meeting — phase 1 (mic-in-use only; calendar deferred)

## Goal

Passively detect when the microphone is in use by *another* app (i.e. a likely
meeting) and surface a subtle, one-click cue offering to start recording. The
cue is a small floating HUD panel below the menu bar; clicking **Start
recording** runs the existing recording path. The feature is gated by a Settings
toggle, default ON.

Explicitly out of scope for this phase: calendar/EventKit signals, camera
detection, running-meeting-app detection. Those are deferred (see Out of scope).

## Current state

- `AppCoordinator` (`Amanuensis/AppCoordinator.swift:23`) is the `@MainActor @Observable`
  composition root. `startRecording()` (`:127`) already handles permissions →
  folder → `RecordingSession`; it does **not** require the app to be frontmost,
  so it is safe to trigger from a background cue. The recording lifecycle is a
  pure `RecorderStateMachine` with effects performed outside it
  (`Packages/AudioPipeline/Sources/RecordingCore/RecorderStateMachine.swift`).
- The app is a persistent menu-bar `.accessory` app: `MenuBarExtra` (`.menu`
  style) in `Amanuensis/AmanuensisApp.swift:10`, with
  `applicationShouldTerminateAfterLastWindowClosed → false`
  (`Amanuensis/AppDelegate.swift`). The menu-bar icon is already driven by
  `coordinator.isRecording`.
- Core Audio property-access idioms already exist in
  `Packages/AudioPipeline/Sources/RecordingCore/ProcessTapRecorder.swift`:
  `AudioObjectGetPropertyData` + `AudioObjectPropertyAddress`, a dedicated
  dispatch queue for callbacks, and `@unchecked Sendable` / `@Sendable nonisolated`
  wrappers for audio-thread closures (the project's documented rule — see the
  `feedback_mainactor_closure_sendable_audio` memory).
- `AppSettings` (`Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`)
  is an `@Observable` UserDefaults-backed prefs object; `SettingsView`
  (`Amanuensis/UI/SettingsView.swift`) renders a grouped `Form` of toggles.
- RecordingCore's default actor isolation is `MainActor` (project-wide setting),
  so new types are implicitly `@MainActor` unless marked `nonisolated`.

## Decisions

- **Signal:** `kAudioDevicePropertyDeviceIsRunningSomewhere` on the **default
  input device**. `true` ⇒ some process is actively running that input. We do
  *not* open the mic ourselves — we only read a HAL property, so this should not
  trip the mic privacy indicator nor require a new entitlement beyond the
  microphone permission the app already holds (flagged for verification).
- **Default-input scope, stated limitation:** we track the default input device
  and re-attach when it changes (`kAudioHardwarePropertyDefaultInputDevice`). A
  meeting on a *non-default* mic will not be detected. Acceptable for phase 1.
- **Pure policy + effectful shell**, mirroring `RecorderStateMachine`: a pure,
  unit-tested `MicCuePolicy` decides *when* to show/hide; `MicActivityMonitor`
  (Core Audio) and `MicCueController` (NSPanel) are the effectful edges; the
  coordinator wires them and owns the timers.
- **Cue:** non-activating floating `NSPanel`, top-right under the menu bar, fixed
  inset — *not* aligned to the `NSStatusItem` (SwiftUI doesn't expose its frame;
  alignment would be fragile).
- **Debounce ~1.5 s** before showing, to absorb brief mic probes (apps that
  momentarily open the input). **Auto-dismiss ~8 s.**
- **Fire once per continuous mic session.** Re-arm only after the mic actually
  goes idle. Starting a recording (from anywhere), dismissing, or auto-dismiss
  all "consume" the current session — no nagging mid-call.
- **Self-suppression:** the policy only arms while the coordinator is idle, and
  any non-idle transition consumes the session — so our own recording (which
  opens the mic) never triggers the cue, and we don't re-prompt for the rest of
  a call after recording stops.
- **No launch-into-meeting surprise:** the monitor's *first* reported value is a
  baseline (sets state without arming). Only a subsequent false→true edge arms.
- **Gating:** `AppSettings.suggestRecordingWhenMicInUse: Bool`, default `true`.
  Toggling it starts/stops the monitor.

## Components

### `MicActivityMonitor` — new, `Packages/AudioPipeline/Sources/RecordingCore/MicActivityMonitor.swift`

`@MainActor final class`. Effectful Core Audio wrapper.

- `func start(onChange: @escaping @Sendable @MainActor (Bool) -> Void)` /
  `func stop()`.
- Installs an `AudioObjectAddPropertyListenerBlock` for
  `kAudioDevicePropertyDeviceIsRunningSomewhere` on the current default input
  device, dispatched to a private serial queue (same pattern as the tap's IO
  queue). The listener block is `@Sendable nonisolated`; it reads the fresh
  `UInt32` value via a `nonisolated static` helper and hops to the main actor
  (`Task { @MainActor in onChange(running) }`).
- Installs a second listener for `kAudioHardwarePropertyDefaultInputDevice` on
  `kAudioObjectSystemObject`; on change, removes the old device listener,
  resolves the new default input device, re-attaches, and reports its current
  running state.
- On `start()`, reports the current value once (the baseline).
- On failure (`status != noErr`), logs via the existing `os.Logger` pattern and
  stays inert — recording is unaffected.

### `MicCuePolicy` — new, `Packages/AudioPipeline/Sources/RecordingCore/MicCuePolicy.swift`

Pure `struct`, no timers/IO. The brains; fully unit-tested.

- **Phases:** `idle → armed → shown → consumed`.
- **Cached inputs:** `enabled: Bool`, `coordinatorIdle: Bool`, `micRunning: Bool?`
  (nil until first report — the baseline).
- **Actions:** `.none`, `.startDebounce`, `.showCue`, `.hideCue`.
- **Events & rules:**
  - `enabledChanged(Bool)` — updates flag. Disabling hides if shown and resets to
    `idle`. Enabling does **not** retro-arm an already-running mic (no edge).
  - `micRunningChanged(Bool)`:
    - first call (was `nil`): set baseline, no action.
    - `false→true` (rising edge): if `enabled && coordinatorIdle && phase == idle`
      → `armed`, `.startDebounce`; otherwise → `consumed`, `.none`.
    - `→false`: reset to `idle`; `.hideCue` if was `shown`, else `.none`. (This is
      the only re-arm path.)
  - `debounceElapsed`: if still `armed && enabled && micRunning == true &&
    coordinatorIdle` → `shown`, `.showCue`; else abort (→ `idle`/`consumed`),
    `.none`.
  - `recordingActivityChanged(isIdle:)`: updates flag. Becoming non-idle →
    `consumed` (abort `armed`/`shown`), `.hideCue` if was `shown`. Becoming idle
    → no arm (needs an edge).
  - `cueDismissed`: `shown → consumed`, `.none` (controller hides itself).

### `MicCueController` + `MicCueView` — new, `Amanuensis/UI/MicCueController.swift`, `Amanuensis/UI/MicCueView.swift`

- `MicCueController` (`@MainActor`): owns a borderless **non-activating** `NSPanel`
  (`styleMask: [.nonactivatingPanel]`, `level = .statusBar`,
  `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`,
  `isFloatingPanel = true`, `hidesOnDeactivate = false`) hosting `MicCueView` via
  `NSHostingView`. `show(onStart:onDismiss:)` positions it top-right under the
  menu bar (main screen `visibleFrame`, fixed inset) and starts an ~8 s
  auto-dismiss timer; `hide()` tears it down. Both auto-dismiss and the ✕ button
  call `onDismiss`; the Start button calls `onStart` and the controller hides
  immediately for responsiveness.
- `MicCueView` (SwiftUI): the HUD from the approved mockup — "🎙 Mic in use",
  a **Start recording** button, and a ✕ dismiss.

### `AppCoordinator` — modify, `Amanuensis/AppCoordinator.swift`

- New stored: `private let micMonitor = MicActivityMonitor()`,
  `private var micCuePolicy = MicCuePolicy()`, `private let micCueController =
  MicCueController()`, `private var micDebounceTask: Task<Void, Never>?`.
- In `init` (end): seed `micCuePolicy.enabledChanged(settings.suggestRecordingWhenMicInUse)`
  and, if enabled, `micMonitor.start { [weak self] running in self?.handleMicRunning(running) }`.
- `handleMicRunning(_:)`, plus feeding recording-activity changes: wherever the
  lifecycle phase changes (start/stop/convert), call
  `apply(micCuePolicy.recordingActivityChanged(isIdle: !isBusy && !isRecording))`.
  A single `private func apply(_ action: MicCuePolicy.Action)` performs effects:
  - `.startDebounce` → `micDebounceTask = Task { try? await Task.sleep(...1.5s); apply(micCuePolicy.debounceElapsed) }`
  - `.showCue` → `micCueController.show(onStart: { self.startMicCueRecording() }, onDismiss: { self.apply(self.micCuePolicy.cueDismissed) })`
  - `.hideCue` → cancel debounce task + `micCueController.hide()`
- `startMicCueRecording()` → `Task { await startRecording() }` (the existing path;
  the resulting busy transition consumes the session and hides the cue).
- `setMicCueEnabled(_:)` called by Settings: `apply(micCuePolicy.enabledChanged($0))`
  and start/stop `micMonitor` accordingly.

### `AppSettings` — modify

- New `public var suggestRecordingWhenMicInUse: Bool` with `didSet` persistence,
  default `true` (object-absent check, like `keepOriginalCAF`). New `Keys` entry.

### `SettingsView` — modify

- New `Section("Meetings")` with a toggle bound to
  `$settings.suggestRecordingWhenMicInUse`, label "Offer to record when the mic is
  in use" + caption explaining the passive default-input detection and its
  limitation. The view (or coordinator via an `onChange`) calls
  `coordinator.setMicCueEnabled(_:)`. Bump the `.frame` height for the new section.

## Data flow

```
default input device  IsRunningSomewhere  ──► (CA listener, private queue)
        │
        ▼  Task { @MainActor }
MicActivityMonitor onChange(Bool)
        │
        ▼  AppCoordinator.handleMicRunning
MicCuePolicy.micRunningChanged(true)  ──► .startDebounce
        │  (Task.sleep ~1.5s)
        ▼
MicCuePolicy.debounceElapsed  ──► .showCue
        │
        ▼
MicCueController.show(...)        floating NSPanel, top-right, ~8s timer
        │
   user clicks Start ─────────────► AppCoordinator.startRecording()  (existing path)
        │                                  │ busy transition
        │                                  ▼
        └── auto-dismiss / ✕ ──► cueDismissed   recordingActivityChanged(isIdle:false)
                                     │                 │
                                     ▼                 ▼
                                 consumed          consumed + .hideCue
```

Re-arm requires the mic to go idle (`micRunningChanged(false)`) and rise again.

## Error handling

- CA listener install failure: monitor logs (`os.Logger` + `LogStore` where a
  coordinator hook is convenient) and stays inert; feature degrades to off, no UI
  error surface, recording unaffected.
- Default-input-device resolution failure on a device change: keep the last
  state; log; do not crash.
- No new failure path reaches the `RecorderStateMachine` / menu bar.

## Tests

- **SPM, `RecordingCoreTests` — `MicCuePolicyTests` (new):** the heart of the
  feature. Cases:
  - baseline first report does not arm;
  - rising edge while enabled+idle → `.startDebounce`, then `debounceElapsed` →
    `.showCue`;
  - mic falling while shown → `.hideCue` and re-arm on next rise;
  - fire-once-per-session: second rise without an intervening fall does not
    re-show;
  - self-suppression: rising edge while not idle → no cue; busy transition while
    shown → `.hideCue` + consumed;
  - debounce aborted when conditions change mid-debounce;
  - `cueDismissed` / auto-dismiss consumes (no re-show until mic cycles);
  - disabled: rising edge produces no cue; disabling while shown hides.
- **SPM, `AppSettingsTests`:** `suggestRecordingWhenMicInUse` defaults to `true`
  and round-trips through UserDefaults.
- **App-hosted / manual** (`MicActivityMonitor` live + HUD panel; needs a real
  audio device and `NSApp`):
  - join a meeting (or open Photo Booth) → HUD appears after ~1.5 s; click Start →
    records; HUD gone.
  - decline (✕ / wait ~8 s) → HUD gone; no re-prompt for that call; ends and a new
    call re-prompts.
  - our own recording started from the menu does **not** trigger the cue.
  - toggle the Settings switch off → no cue; on → cue returns.

## Out of scope (deferred)

- Calendar / EventKit "scheduled meeting" signal (explicitly deferred this phase).
- Camera-in-use (CoreMediaIO) and running-meeting-app (`NSWorkspace`) signals.
- Detecting non-default input devices.
- Aligning the HUD horizontally to the menu-bar status item.
- Auto-*starting* recording (this phase only offers a one-click cue).
- Snooze / per-app allow-lists.
