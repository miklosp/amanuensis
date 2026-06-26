# Permissions

Every OS permission Amanuensis requests, why it needs it, and where it is
declared. This is the single source of truth for review, audit, and an
eventual privacy / App Store submission.

Permissions come from two distinct mechanisms:

- **Entitlements** — signed into the app at build time; grant App Sandbox
  capabilities. Most live in `Amanuensis/Amanuensis.entitlements`, but one is
  injected by a build setting (see the note below the table).
- **Runtime TCC permissions** — requested from the user at runtime via system
  prompts or System Settings; gate access to the mic, system audio, key
  events, and event posting.

The app runs under **App Sandbox** (`ENABLE_APP_SANDBOX = YES`) with
**Hardened Runtime** (`ENABLE_HARDENED_RUNTIME = YES`).

## Entitlements

| Entitlement | Value | Why | Where |
|---|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Runs the app inside the App Sandbox. | entitlements file |
| `com.apple.security.network.client` | `true` | Outbound calls to provider / transcription APIs. | entitlements file |
| `com.apple.security.device.audio-input` | `true` | Microphone capture and the Core Audio process tap. | entitlements file |
| `com.apple.security.assets.music.read-write` | `true` | Promptless access to `~/Music`; the default recordings folder is `~/Music/Amanuensis`. | entitlements file |
| `com.apple.security.files.user-selected.read-write` | `readwrite` | Read/write recordings folders the user picks via the open panel, persisted as security-scoped bookmarks. | **build setting** `ENABLE_USER_SELECTED_FILES`, not the entitlements file |

> **Note:** `files.user-selected.read-write` does **not** appear in
> `Amanuensis.entitlements`. It is produced by the build setting
> `ENABLE_USER_SELECTED_FILES = readwrite` and only shows up in the signed
> `.xcent` at build time. Don't go looking for it in the entitlements plist.

## Runtime TCC permissions

| Permission | Prompt? | Why | Requested in | Notes |
|---|---|---|---|---|
| Microphone | Yes (system) | Record the mic; capture dictation audio. | `MicrophonePermission` | Standard public API (`AVCaptureDevice.requestAccess(for: .audio)`). |
| System Audio Capture | Yes (system, on first tap) | Capture other apps' audio via the Core Audio process tap. | `AudioCapturePermission` | **Private SPI** (`kTCCServiceAudioCapture`, dlopen'd). Without the grant the tap records silence. |
| Input Monitoring | Yes (System Settings) | Listen-only global key tap for the dictation trigger. | `HotkeyTapMonitor` | Sandbox-compatible; the tap observes, never consumes (`CGRequestListenEventAccess`). |
| Post Events (shown under Accessibility) | Yes (System Settings) | Synthetic ⌘V to insert dictated text at the cursor. | `TextInserter` | Not the full Accessibility privilege; sandbox-compatible (`CGRequestPostEventAccess`). |

## Source of truth in the code

- Entitlements: `Amanuensis/Amanuensis.entitlements` plus the build-setting
  `ENABLE_USER_SELECTED_FILES` (above).
- Microphone — `Packages/AudioPipeline/Sources/RecordingCore/MicrophonePermission.swift`
- System Audio Capture — `Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift`
- Input Monitoring — `Amanuensis/Dictation/HotkeyTapMonitor.swift`
- Post Events — `Amanuensis/Dictation/TextInserter.swift`

## Mac App Store

The **System Audio Capture** grant uses a private TCC SPI
(`kTCCServiceAudioCapture`). That private SPI is the single thing keeping
Amanuensis off the Mac App Store today — every other permission here is
App-Store-compatible. See the M1 notes for the longer history.
