# Dictation Polish — Design Spec

**Date:** 2026-06-21
**Branch:** `feat/dictation-polish` (already created off `main` @ `f90648b`, the PR #5 merge)
**Status:** Approved design, ready for implementation planning.

Three independent improvements to the dictation feature, bundled into one branch. Each can be implemented and reviewed on its own; they share no state. Implement in any order; suggested order is #2 (doc, no code), then #1 (small), then #3 (medium).

A reader new to this work should also read `docs/superpowers/specs/2026-06-18-dictation-design.md` (the original dictation design) and `reference_avaudiofile_writer_gotchas` in auto-memory for context. The dictation feature is verified working end-to-end under App Sandbox.

---

## Improvement 1 — Suppress the mic-in-use cue during our own dictation

### Problem
The "offer to record when the mic is in use" cue appears when the user starts a **dictation** (dictation opens the mic via `AVAudioEngine`). It should only offer to record when *another* app uses the mic, not when we opened it ourselves.

### Root cause
`MicCuePolicy` (`Packages/AudioPipeline/Sources/RecordingCore/MicCuePolicy.swift`) arms the cue only on a mic false→true rising edge **while the coordinator is idle** (`coordinatorIdle == true`). Active *recording* already suppresses the cue because the recorder feeds `recordingActivityChanged(isIdle:)`. Dictation is a second source of "our own mic use," but it does **not** mark the coordinator busy — so a dictation that holds the mic longer than the cue debounce (~1.5 s) false-triggers the cue. (Dictations shorter than the debounce already escape it, because the mic falls idle before `debounceElapsed` fires — so the bug is only visible on longer dictations.)

### Fix (recommended: guard in the driver)
In `AppCoordinator.handleMicRunning(_:)` (`Amanuensis/AppCoordinator.swift`, ~line 362), ignore mic-running reports while dictation is active:

```swift
private func handleMicRunning(_ running: Bool) {
    // Our own dictation opens the mic; don't let that arm the "record this?" cue.
    guard dictation.phase == .idle else { return }
    apply(micCuePolicy.micRunningChanged(running))
}
```

`dictation` is the `DictationCoordinator` already held by `AppCoordinator`; `phase` is `private(set)` and readable. This drops both edges while dictation runs, so dictation's mic use can't arm the cue; an external app that grabs the mic *before* dictation still arms it normally (the rising edge happened while `phase == .idle`).

**Rationale for the guard over modeling it in the policy:** the guard is one line, touches no tested code, and the suppression is conceptually identical to "don't nag while we're using the mic." The downside is it isn't unit-tested (it's in the app-target driver).

**Alternative (only if you want it unit-tested):** add a first-class `dictationActive` input to `MicCuePolicy` (a new `dictationActivityChanged(isActive:)` event mirroring `recordingActivityChanged`), fed from `DictationCoordinator` phase transitions. More code, more surface, but testable in the pure policy. The guard is the default; pick this only if review prefers it.

### Files
- `Amanuensis/AppCoordinator.swift` (guard) — or, for the alternative, also `MicCuePolicy.swift` + a wiring callback from `DictationCoordinator`.

### Testing
Guard approach: no headless test (app-target driver); verify manually — start a >2 s dictation and confirm no record cue appears; confirm an actual external mic use (e.g. a meeting app) still shows the cue. If the policy-input alternative is chosen, add `MicCuePolicyTests` cases (dictation-active suppresses arming; clears on inactive).

---

## Improvement 2 — Permissions documentation

### What
A new tracked doc, `docs/permissions.md` (committed), enumerating every OS permission the app requests, why, and where. Single source of truth for review/audit and for an eventual privacy/App-Store submission.

### Source of truth in the code
- Entitlements: `Amanuensis/Amanuensis.entitlements` plus the build-setting-generated `ENABLE_USER_SELECTED_FILES = readwrite` (this one is **not** in the entitlements file — it is injected at build time and appears only in the signed `.xcent`; the doc must call that out).
- Runtime TCC requests:
  - Microphone — `Packages/AudioPipeline/Sources/RecordingCore/MicrophonePermission.swift` (`AVCaptureDevice.requestAccess(for: .audio)`)
  - System Audio Capture — `Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift` (**private** TCC SPI `kTCCServiceAudioCapture`, dlopen'd)
  - Input Monitoring — `Amanuensis/Dictation/HotkeyTapMonitor.swift` (`CGRequestListenEventAccess`)
  - Post Events — `Amanuensis/Dictation/TextInserter.swift` (`CGRequestPostEventAccess`)

### Required content (table)
Two tables. **Entitlements:**

| Entitlement | Value | Why | Where |
|---|---|---|---|
| `com.apple.security.app-sandbox` | true | App Sandbox on | entitlements file |
| `com.apple.security.network.client` | true | Outbound provider/transcription API calls | entitlements file |
| `com.apple.security.device.audio-input` | true | Mic capture + Core Audio process tap | entitlements file |
| `com.apple.security.assets.music.read-write` | true | Promptless `~/Music` access; default recordings folder `~/Music/Amanuensis` | entitlements file |
| `com.apple.security.files.user-selected.read-write` | (readwrite) | User-picked recordings folders via the open panel + security-scoped bookmarks | **build setting** `ENABLE_USER_SELECTED_FILES`, not the entitlements file |

**Runtime TCC permissions:**

| Permission | Prompt? | Why | Requested in | Notes |
|---|---|---|---|---|
| Microphone | Yes (system) | Record mic; dictation capture | `MicrophonePermission` | Standard public API |
| System Audio Capture | Yes (system, on first tap) | Capture other apps' audio via Core Audio process tap | `AudioCapturePermission` | **Private SPI (`kTCCServiceAudioCapture`) → Mac App Store blocker.** Without the grant the tap records silence. |
| Input Monitoring | Yes (System Settings) | Listen-only global key tap for the dictation trigger | `HotkeyTapMonitor` | Sandbox-compatible; listen-only |
| Post Events (listed under Accessibility) | Yes (System Settings) | Synthetic ⌘V to insert dictated text | `TextInserter` | Not the full Accessibility privilege; sandbox-compatible |

Each row's "Why" should be one user-facing sentence. Add a short intro paragraph and a one-line note that the System-Audio-Capture private SPI is the single thing keeping the app off the Mac App Store today (cross-reference the existing M1 notes).

### Testing
None (documentation). "Tracked" = committed to git.

---

## Improvement 3 — Trigger key: select any standard Mac modifier (left/right aware)

### Decision (locked)
Modifiers **only** — no arbitrary keys, no chords. The Settings control is a **list of every modifier key on a standard Mac keyboard** (a `Picker`, same control as today, more rows) — **not** a key-capture field. Keep both interaction styles from today: tap = toggle, hold = push-to-talk. Differentiate left vs right where the key has two.

Include **Fn** and **Caps Lock** as options (the user wants Caps Lock bindable — "reserve that button"). See the hard constraints on those two below; they are best-effort and must be verified empirically during implementation.

### `TriggerSide` → `TriggerModifier` (rename + expand)
Rename `Packages/AudioPipeline/Sources/DictationCore/TriggerSide.swift`'s `TriggerSide` to `TriggerModifier` (the meaning changed from "which side of ⌘" to "which modifier key"). Keep the existing `leftCommand`/`rightCommand` **raw-value case names** so persisted `DictationSettings` decode unchanged (no migration). Default stays `.rightCommand`.

Each case carries: virtual `keyCode`, the L/R device-flag bit (for momentary modifiers), a `displayName`, and an `interaction` (momentary vs latching). Table:

| Case | keyCode | device flag bit (`event.flags.rawValue &`) | Display | Interaction |
|---|---|---|---|---|
| `leftControl` | 59 (0x3B) | 0x0000_0001 (`NX_DEVICELCTLKEYMASK`) | "Left ⌃" | momentary |
| `rightControl` | 62 (0x3E) | 0x0000_2000 (`NX_DEVICERCTLKEYMASK`) | "Right ⌃" | momentary |
| `leftShift` | 56 (0x38) | 0x0000_0002 (`NX_DEVICELSHIFTKEYMASK`) | "Left ⇧" | momentary |
| `rightShift` | 60 (0x3C) | 0x0000_0004 (`NX_DEVICERSHIFTKEYMASK`) | "Right ⇧" | momentary |
| `leftOption` | 58 (0x3A) | 0x0000_0020 (`NX_DEVICELALTKEYMASK`) | "Left ⌥" | momentary |
| `rightOption` | 61 (0x3D) | 0x0000_0040 (`NX_DEVICERALTKEYMASK`) | "Right ⌥" | momentary |
| `leftCommand` | 55 (0x37) | 0x0000_0008 (`NX_DEVICELCMDKEYMASK`) | "Left ⌘" | momentary |
| `rightCommand` | 54 (0x36) | 0x0000_0010 (`NX_DEVICERCMDKEYMASK`) | "Right ⌘" | momentary |
| `function` | 63 (0x3F) | use `CGEventFlags.maskSecondaryFn` = 0x80_0000 | "Fn 🌐" | momentary |
| `capsLock` | 57 (0x39) | use `CGEventFlags.maskAlphaShift` = 0x1_0000 | "Caps Lock ⇪" | latching |

Note: a standard Apple laptop keyboard has only a *left* Control physically, but right Control exists on external keyboards and has a real keycode, so it is included. The UI may group/label as it sees fit; the pure enum lists all ten.

The existing `keyCode` computed property generalizes to a stored mapping; add `deviceFlagBit: UInt64?` (nil for none) and `interaction`. The pure mapping logic is testable.

### Interaction model — momentary vs latching
- **Momentary modifiers (the 8 sided keys + Fn):** unchanged model. `HotkeyTapMonitor` reads `flagsChanged`, matches `keyCode == trigger.keyCode`, and decides down vs up via `(event.flags.rawValue & trigger.deviceFlagBit) != 0`. `ModifierGestureRecognizer` is **unchanged** — it already turns trigger down/up + foreign input into tap/hold/cancel gestures. So Fn and the new modifiers get tap-toggle and hold-to-talk for free.
- **Caps Lock (latching) — special, best-effort:** Caps Lock does not report a momentary physical down/up; its `maskAlphaShift` flag reflects caps *state*, which toggles each press. So the down/up model does not apply. For `capsLock`, `HotkeyTapMonitor` should emit a single **toggle** per caps `flagsChanged` event (synthesize a tap, or signal the coordinator directly), giving tap-to-toggle dictation only — **no hold-to-talk**.

### Hard constraints to document and verify (Fn, Caps Lock)
These must be surfaced to the user in the UI (a short caption) and verified manually during implementation:
1. **Caps Lock cannot be "reserved."** The listen-only, sandbox-safe `CGEventTap` observes but does not consume events and cannot remap keys. So binding dictation to Caps Lock **does not stop Caps Lock from toggling caps state** — the LED/caps will still flip on each trigger. True reservation needs a non-sandbox HID remap (hidutil/Karabiner-style), which is out of scope and Mac-App-Store-incompatible.
2. **Verify the session tap actually delivers Caps Lock events.** Confirm a `.cgSessionEventTap` listen-only tap receives `flagsChanged` with keycode 57 before committing to the binding. If it doesn't arrive cleanly, ship Caps Lock **disabled/omitted** rather than broken, and note it.
3. **Fn may conflict with macOS.** If the user has System Settings → Keyboard → "Press 🌐/fn to" set to Dictation/Emoji/Input-Source, the OS also acts on Fn. We still observe it, but the OS side-effect can't be suppressed. Document this; Fn otherwise works as a momentary trigger.

If, on manual verification, Caps Lock proves unreliable or unpleasant, it is acceptable to land #3 with Caps Lock omitted and the rest shipped — note the omission explicitly (don't silently drop it).

### `HotkeyTapMonitor` changes
`Amanuensis/Dictation/HotkeyTapMonitor.swift`: replace the hard-coded `leftCmdBit`/`rightCmdBit` with a lookup from `trigger.deviceFlagBit`. Keep `keyDown → foreignInput` unchanged. Add the Caps Lock latching branch (emit toggle) and the Fn branch (uses `maskSecondaryFn`). The keycode-equality check plus the per-modifier bit is the whole change for momentary keys.

### Settings UI
`Amanuensis/UI/SettingsView.swift` (~line 56): replace the 2-row trigger `Picker` with rows for all `TriggerModifier` cases (consider grouping by key, L/R adjacent). Keep the existing `.onChange { coordinator.dictation.settingsChanged() }`. Add a caption under the picker noting the Caps Lock (still toggles caps) and Fn (may conflict with macOS) caveats when those are selected. No event-capture monitor, no new permission.

### Persistence / migration
`DictationSettings.trigger` type changes `TriggerSide` → `TriggerModifier`. Because the two existing case raw values are preserved, stored settings decode unchanged. No migration step.

### Files
- `Packages/AudioPipeline/Sources/DictationCore/TriggerSide.swift` → rename to `TriggerModifier.swift`, expand.
- `Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift` — field type.
- `Packages/AudioPipeline/Sources/DictationCore/ModifierGestureRecognizer.swift` — `var trigger` type rename only (logic unchanged).
- `Amanuensis/Dictation/HotkeyTapMonitor.swift` — generalized bit lookup + Fn/Caps branches.
- `Amanuensis/UI/SettingsView.swift` — expanded picker + caption.
- Tests: rename `TriggerSideTests` → `TriggerModifierTests`; cover keyCode/deviceFlagBit/displayName/interaction for every case. `ModifierGestureRecognizerTests` adjust for the type rename (logic unchanged).

### Testing
- DictationCore (pure, `swift test`): every `TriggerModifier` case's keycode/bit/interaction/display; gesture recognizer unchanged behavior under the renamed type.
- App-target (`HotkeyTapMonitor`, Settings UI): no headless test (effectful edge / real key events), consistent with the codebase. Build + manual: bind each momentary modifier and confirm tap-toggle and hold-to-talk; confirm Fn; confirm/curate Caps Lock per the constraints above.
- After SPM tests, rebuild the app target (per CLAUDE.md) via the xcode-build daemon.

---

## Decisions log
- **D1** — Three improvements share one branch (`feat/dictation-polish`), independent commits.
- **D2** — #1 fixed with a one-line guard in `handleMicRunning` (not modeled in `MicCuePolicy`), for minimalism; policy-input alternative documented if review wants it tested.
- **D3** — #3 is modifiers-only, presented as a **list/picker of all standard Mac modifier keys**, not a capture field.
- **D4** — Keep both interactions (tap-toggle, hold-PTT) for momentary modifiers; Caps Lock is toggle-only.
- **D5** — Rename `TriggerSide` → `TriggerModifier`; preserve existing raw-value case names → no settings migration; default stays Right ⌘.
- **D6** — Caps Lock cannot be truly "reserved" under the sandbox listen-only design; included best-effort with documented caveats and a verify-or-omit escape hatch. Fn included; OS-conflict documented.
- **D7** — Permissions doc lives at `docs/permissions.md`, committed; must call out that `files.user-selected.read-write` comes from a build setting, not the entitlements file, and that System-Audio-Capture is a private SPI / MAS blocker.

## Out of scope / follow-ups
- True Caps Lock reservation (HID remap) — out of scope, MAS-incompatible.
- Arbitrary keys / chord hotkeys — explicitly rejected this round (modifiers only).
- The separately-tracked job-runner follow-ups (observability, opaque decode) — see `docs/job-runner-follow-ups.md`; unrelated to this branch.
