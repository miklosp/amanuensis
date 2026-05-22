---
title: Swift modules & gotchas — audio-pipeline
status: living document
created: 2026-05-20
owner: Miklos
---

# Swift modules & gotchas

Project-specific cheatsheet for the frameworks this app uses and the traps to avoid. Scoped to M1/M2/M4 of `audio-pipeline-project-doc.md`. Not a general Swift primer — only what's relevant here.

Module sections are tagged `[M1]`, `[M2]`, `[M4]` so you can skip what isn't yet in scope.

## Concurrency baseline (all milestones)

The project builds with:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every type, function, and closure is implicitly `@MainActor` unless opted out.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` — strict diagnostics.
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — public re-exports do not leak.

Implications for audio code:

- Audio callbacks (Core Audio IOProcs, AVAudioEngine taps) run on real-time threads, not the main actor. Mark these closures and the methods they call `nonisolated`, and ensure captured state is `Sendable`. A main-isolated `self` captured into a tap closure will not compile.
- Don't allocate or take locks inside a real-time audio callback. No `Task { @MainActor in ... }`, no `os_unfair_lock` you might contend, no Swift dictionaries you might rehash. Use a lock-free SPSC ring buffer or a `DispatchQueue` (non-real-time consumer) to hand work off; the UI reads from there.
- `AVAudioPCMBuffer` is an `NSObject` reference type. Crossing actor boundaries requires copying its contents into a `Sendable` value, or `@unchecked Sendable` with a documented thread-handoff invariant.

## App Sandbox & entitlements (all milestones)

Current state in `project.pbxproj`:

- `ENABLE_APP_SANDBOX = YES`
- `ENABLE_USER_SELECTED_FILES = readonly`
- No `.entitlements` file exists yet — create it when adding the first capability and wire `CODE_SIGN_ENTITLEMENTS` to its path.

What you'll need per feature:

| Feature | Entitlement | Info.plist usage description |
|---|---|---|
| Mic capture | `com.apple.security.device.microphone` | `NSMicrophoneUsageDescription` |
| System audio (process tap) | `com.apple.security.device.audio-input` | `NSAudioCaptureUsageDescription` |
| Write to `~/Library/Application Support/<bundle>` | none — allowed by default under sandbox | — |
| Write outside Application Support | `com.apple.security.files.user-selected.read-write` (only via NSOpenPanel) | — |
| Keychain (single-app) | none | — |
| Network (cloud connectors, M2+) | `com.apple.security.network.client` | — |
| Accessibility / paste (M4) | not an entitlement — runtime TCC prompt | `NSAppleEventsUsageDescription` if scripting other apps |

**Open question that affects M1 design:** sandboxed Core Audio process taps are under-documented and AudioCap (the reference impl) ships un-sandboxed. Realistic M1 plan: develop sandboxed, fall back to un-sandboxed Developer ID distribution if the tap doesn't survive sandboxing. Revisit before Mac App Store distribution. The project doc already calls this out as M1-deferred.

## CoreAudio — system audio capture [M1]

Used for: `AudioHardwareCreateProcessTap`, `CATapDescription`, private aggregate device, IOProc.

- API floor: macOS 14.4. Project targets macOS 26 to dodge known bugs.
- The IOProc is a C function pointer (`AudioDeviceIOProc`). Bridge via a `nonisolated(unsafe)` static or a `@convention(c)` closure that does not capture state — `context` pointer is your only channel.
- The aggregate device built to read the tap is **private** (not visible in Audio MIDI Setup). It must be destroyed on stop with `AudioHardwareDestroyAggregateDevice`, and the tap with `AudioHardwareDestroyProcessTap`. App crash → leaked device that may persist until reboot.
- **Tahoe attenuation bug:** pro-audio interfaces with multiple output pairs record ~12 dB low through the tap. Built-in speakers and AirPods are fine. Document on first run, surface an input-gain control later — do not silently compensate at capture time.
- The aggregate device must include a **real output device as a sub-device** (not the tap alone) — the HAL needs it for the IO clock, or the IOProc never fires. `ProcessTapRecorder` already does this.

### System-audio capture permission (the silent-failure trap) [M1]

A process tap needs the **`kTCCServiceAudioCapture`** TCC permission ("System Audio Recording Only"), which is separate from the microphone permission. The hard part is how it fails:

- **It fails silent.** Without the permission, `AudioHardwareCreateProcessTap` still succeeds, the aggregate device builds, and the IOProc fires on schedule — but every buffer is pure silence. No error, no warning. (Confirmed by dumping the raw IOProc input: all zeros.)
- **No public API to request it.** Request `kTCCServiceAudioCapture` via the private TCC SPI — `TCCAccessRequest` / `TCCAccessPreflight`, `dlopen`'d from `TCC.framework` — see `AudioCapturePermission.swift`. Call it *before* creating the tap. Private framework: fine for Developer ID, a hard Mac App Store blocker.
- **`NSAudioCaptureUsageDescription` must reach the built `Info.plist`, and Xcode drops it.** Without the usage string TCC has nothing to display, so `TCCAccessRequest` denies without ever prompting. Trap: `GENERATE_INFOPLIST_FILE = YES` only injects the `INFOPLIST_KEY_*` Xcode recognises and **silently discards `INFOPLIST_KEY_NSAudioCaptureUsageDescription`**. The project ships a real `Info.plist` instead (`GENERATE_INFOPLIST_FILE = NO`, `INFOPLIST_FILE = Info.plist`). Verify after building: `plutil -p <app>/Contents/Info.plist | grep UsageDescription`.
- **Code signing must be stable or TCC grants don't persist.** Ad-hoc / per-build signatures make macOS treat every rebuild as a new app — grants reset and you are re-prompted each launch. Use a stable Apple Development signing identity for development.
- Open question: whether the private SPI is strictly required, or whether the tap auto-prompts once `NSAudioCaptureUsageDescription` is present. Both were in place when it first worked; untested in isolation.

- Reference implementations: [AudioCap by Guilherme Rambo](https://github.com/insidegui/AudioCap) — the canonical setup pattern; the DocC docs under-specify the aggregate-device dance. Also [Capturing system audio on macOS: Core Audio vs ScreenCaptureKit](https://www.aitchdien.com/posts/capturing-system-audio-macos-core-audio-vs-screencapturekit) — corroborates the TCC, Info.plist, and code-signing traps above.

## AVFoundation — mic + file I/O [M1]

Used for: `AVAudioEngine`, `AVAudioInputNode`, `AVAudioFile`, `AVAudioPCMBuffer`, `AVCaptureDevice` (for permission).

- No `AVAudioSession` on macOS. Buffer size and latency are per-engine.
- `inputNode.installTap(onBus:bufferSize:format:)` closure runs on an audio thread. Same `nonisolated`/`@Sendable` rules as Core Audio.
- `AVAudioFile.write(from:)` is **synchronous and blocking**. Calling it from the tap closure works for a single writer but adds jitter under load. For parallel mic + system writers, push buffers onto a dedicated serial `DispatchQueue` consumer and write from there.
- CAF + ALAC writer settings:

  ```swift
  let settings: [String: Any] = [
      AVFormatIDKey:        kAudioFormatAppleLossless,
      AVSampleRateKey:      48_000,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 24,
      AVLinearPCMIsFloatKey:  false,
  ]
  let file = try AVAudioFile(forWriting: url, settings: settings)
  ```

  Container is inferred from the `.caf` extension. ALAC quality keys are ignored (lossless).
- Mic permission: gate on `AVCaptureDevice.requestAccess(for: .audio)` at the user's first record attempt, not at launch.
- Device enumeration: `AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)` for the input picker.

## AudioToolbox (transitive) [M1]

- Low-level C structs surfaced through AVFoundation/CoreAudio interop: `AudioStreamBasicDescription`, `AudioBufferList`, `AudioTimeStamp`.
- `AudioBufferList.mBuffers` is declared as a one-element variable-length array. Iterate via `UnsafeMutableAudioBufferListPointer(&list)`; never index `mBuffers` directly past element 0.
- Use `withUnsafePointer`/`withUnsafeMutablePointer` for ASBD bridging into Core Audio APIs.

## SwiftUI + AppKit — menu bar UI [M1]

Used for: `App`, `Scene`, `MenuBarExtra`, `Settings`, optional `NSStatusItem` fallback, `NSWorkspace`.

- `MenuBarExtra` (macOS 13+) is the SwiftUI-native status item. Style: `.window` for a popover, `.menu` for a classic menu. Use this unless you need a custom hosting view that MBE can't carry — then drop to `NSStatusItem` via `@NSApplicationDelegateAdaptor`.
- **Hide the dock icon at launch:** set `LSUIElement = true` in Info.plist. `NSApp.setActivationPolicy(.accessory)` alone leaves a brief dock-icon flash at startup. Use both for belt-and-braces (Info.plist for cold start, policy for re-activation paths).
- Settings window: provide a `Settings { … }` scene. The standard `⌘,` shortcut and the app menu item wire up automatically.
- "Open recordings folder": `NSWorkspace.shared.open(recordingsURL)`. Sandbox allows opens of paths under your Application Support container without prompts.
- If you need `applicationDidFinishLaunching` (e.g. to register the Carbon hotkey, run an aggregate-device cleanup sweep on startup), use `@NSApplicationDelegateAdaptor(AppDelegate.self)` on the `App` struct.

## Foundation — storage layout [M1]

- URL-based APIs only. `String` paths break under spaces, unicode, and APFS volume moves.
- Application Support container: `URL.applicationSupportDirectory.appending(path: "audio-pipeline", directoryHint: .isDirectory)`. macOS 13+ API.
- ISO-8601 folder names: `ISO8601DateFormatter` with `[.withInternetDateTime]`. Strip the `:` characters before using as a path component — legal on APFS but shell-hostile.
- Atomic writes for metadata sidecars: `try data.write(to: url, options: .atomic)`.
- Create the recording folder tree with `FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)`.

## os.Logger — structured logging [M1]

- `Logger(subsystem: "work.miklos.audio-pipeline", category: "audio")` per subsystem (`audio`, `pipeline`, `ui`, `connector.<name>`). Avoid `print`.
- Privacy defaults to `.private` and shows `<private>` in Console.app. Mark non-sensitive interpolations explicit: `logger.info("recording \(url.lastPathComponent, privacy: .public)")`. Never mark secrets `.public`.
- Use `OSSignposter` for hot paths (audio buffer arrival, file flush) if you need Instruments traces.

## Carbon — global hotkey [M1]

Used for: start/stop/pause global hotkey (M1), push-to-talk dictation hotkey (M4).

- `RegisterEventHotKey` + `InstallEventHandler`. Awkward in Swift but tractable; no third-party `HotKey` package per M1's no-deps rule.
- The event handler is a `@convention(c)` callback. `nonisolated(unsafe)` static or a small trampoline; pass app state through the `userData` pointer.
- No special permission needed to register a hotkey. The user choosing it in Settings is a UI problem, not a TCC one.

## Security — Keychain [M2]

Used for: cloud connector API keys, referenced from pipeline YAML by name.

- Keychain Services C API directly (`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`). No third-party Keychain wrappers.
- Item class: `kSecClassGenericPassword`. Service: `"work.miklos.audio-pipeline"`. Account: the reference name (`"gemini-default"`, etc.).
- Pipeline YAML stores `api_key_ref: keychain://gemini-default`. The runner resolves at execution time. Never the secret in the file.
- Single-app use needs no `keychain-access-groups` entitlement. Add one only if you split a helper out of the main app later.

## SQLite — queue + run history [M2]

Used for: pending pipeline runs (`queue.db`), historical run logs (`runs.db`).

- Link `libsqlite3.tbd`; use the C API or a small Swift trampoline. No GRDB / SQLite.swift per the no-deps rule.
- Enable WAL on open: `PRAGMA journal_mode = WAL;` plus `PRAGMA synchronous = NORMAL;` for crash-safe queue updates with reasonable throughput.
- SQLite is single-writer. One connection per writer thread; reads can run concurrently in WAL.
- Foreign keys: `PRAGMA foreign_keys = ON;` per connection — off by default in SQLite.

## Sparkle — updates [deferred]

- Add via Swift Package Manager when first public release approaches. EdDSA-signed appcast served from GitHub Releases.
- Not needed for M1/M2. Mentioned here so it isn't reinvented.

## Accessibility / Pasteboard — dictation paste [M4]

Used for: M4 push-to-talk paste-into-frontmost-text-field flow.

- Sequence: save current `NSPasteboard.general` contents → set transcript → post `CGEvent` for `⌘V` → restore previous pasteboard contents.
- Requires user-granted Accessibility permission in System Settings. Prompt via:

  ```swift
  let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
  let trusted = AXIsProcessTrustedWithOptions(opts)
  ```

- TCC prompt for Accessibility is **not gated by an entitlement**; it's a system-level grant the user toggles in Settings.
- Restoring the previous pasteboard isn't perfectly reliable across types (especially file URLs). Document the limitation rather than over-engineering the restore.

## Lookup tips

- Local docs corpus is `apple-docs`. Common queries:
  - `apple-docs search "AudioHardwareCreateProcessTap"`
  - `apple-docs read AVAudioEngine --framework avfoundation`
  - `apple-docs browse coreaudio`
- For evolving APIs and missing patterns, AudioCap's source remains the most useful reference for the tap setup that DocC under-specifies.
- For SwiftUI MenuBarExtra patterns, the HIG entry on menu bar extras is in the apple-docs corpus under `human-interface-guidelines/menus`.
