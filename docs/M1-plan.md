---
title: M1 — Recorder, first implementation pass
status: draft
created: 2026-05-21
owner: Miklos
---

# M1 — Recorder, first implementation pass

Scope of this document: refine the M1 section of `audio-pipeline-project-doc.md` into a concrete plan, capture the decisions taken during the first implementation pass, and flag the assumptions a future reader (or future me) needs to know to keep moving.

## What "done" means for this first pass

The smallest thing that satisfies the user request "recording mic + computer audio":

1. Launch the app — it lives in the menu bar, no dock icon.
2. Pick **Start recording** from the menu bar.
3. App captures mic and system audio to two separate `.caf` files inside a new timestamped folder under `~/Library/Application Support/audio-pipeline/recordings/`.
4. Pick **Stop recording**. Both files finalize cleanly; a `meta.json` sidecar is written alongside.
5. **Open recordings folder** opens Finder at the right place so the user can verify.

Not in this first pass, even though the project doc lists them under M1:

- Global hotkey (Carbon). Deferred to next pass — menu bar buttons are enough to verify capture.
- Pause/resume. Stop-and-restart works for the smoke test.
- Per-device input selection UI. First pass uses the system default input.
- Idle CPU / RAM targets. We'll measure once the thing runs.
- Crash-safe partial recovery. ALAC in CAF tolerates abrupt termination as the project doc claims; revisit if the smoke test proves otherwise.

## Decisions taken this pass

### D1. Sandbox: **off** for the first attempt

The project doc and `swift-modules-and-gotchas.md` both flag that Core Audio process taps under App Sandbox are under-documented and that AudioCap (the reference impl) ships un-sandboxed. Two viable strategies:

- (a) keep sandbox on, add `com.apple.security.device.audio-input` + `com.apple.security.device.microphone`, hope the tap survives;
- (b) turn sandbox off for now, get the recording path working end-to-end, revisit sandbox later (before any distribution attempt).

Picking (b) for this pass. Rationale: the priority is "does mic + system capture work at all", not "does it work under sandbox". A working un-sandboxed recorder is more useful than a non-working sandboxed one. The entitlements file is still created and wired up — it just declares minimal entitlements right now, and `ENABLE_APP_SANDBOX = NO` in build settings.

When this is reversed: once recording is verified working, set `ENABLE_APP_SANDBOX = YES`, add the device entitlements, and test again. If the tap breaks, fall back to Developer ID distribution per the gotchas doc.

### D2. Two `.caf`/ALAC files per recording, in a per-recording folder

Mirrors the storage layout in the project doc. The folder is the unit of work for the future pipeline runner. Mic and system stay separate so a downstream `audio.mix` step can decide mixdown policy — we don't bake that decision in at capture time.

Filenames inside the folder: `mic.caf`, `system.caf`, `meta.json`. Folder name is ISO-8601 with `:` stripped (shell-hostile).

### D3. Threading model: capture on real-time thread, write on serial queues

Both AVAudioEngine's `installTap` closure and the Core Audio `AudioDeviceCreateIOProcIDWithBlock` block run on real-time / high-priority audio threads. Per `swift-modules-and-gotchas.md`, we must not allocate, lock, or block in those callbacks.

The first-pass approach: each `AudioFileWriter` owns a dedicated serial `DispatchQueue`. The capture callback wraps the incoming `AudioBufferList` in an `AVAudioPCMBuffer` (with a buffer-list copy, so the source memory's lifetime doesn't matter), then `queue.async`s the write. `AVAudioFile.write(from:)` then runs off the audio thread.

This is not the most efficient possible design — there is one allocation per buffer and one cross-thread hop. A lock-free SPSC ring buffer would beat it. But it is correct, easy to read, and easy to throw away if Instruments shows it's the bottleneck. Good first-pass call.

### D4. AVAudioFile, not ExtAudioFile

`AVAudioFile` is higher-level, handles ALAC encoding from float PCM input automatically, and is the path the gotchas doc recommends. ExtAudioFile would let us write from the IOProc directly with less hand-holding, but the trade-off is more C-level glue. Save for later if needed.

### D5. Match capture sample rate, don't force 48 kHz

The mic input device may be 44.1 kHz, 48 kHz, or something else (Bluetooth headsets in particular often deliver 16 kHz). The tap's native sample rate matches the default output device. Forcing both to 48 kHz means an extra conversion node per recorder, more code, more failure surface.

First pass: each writer is created with the source format's sample rate and channel layout (taken from `inputNode.inputFormat(forBus: 0)` for the mic and from the tap's `kAudioTapPropertyFormat` for the system). The CAF/ALAC settings dict inherits these values. Downstream conversion is a pipeline node's job (M2).

### D6. Capture default devices only

No device picker yet. Mic = system default input. System audio = `CATapDescription(stereoMixdownOfProcesses: [])` which captures all output processes mixed to stereo. Device selection UI is a settings-window feature for the next pass.

### D7. File layout in the source tree

```
audio-pipeline/
  audio_pipelineApp.swift         # @main entry, MenuBarExtra
  AppCoordinator.swift            # ObservableObject, top-level @MainActor state
  Audio/
    AudioFileWriter.swift         # serial-queue AVAudioFile writer
    MicRecorder.swift             # AVAudioEngine mic capture
    ProcessTapRecorder.swift      # Core Audio process tap + aggregate device + IOProc
    AudioFormatBridge.swift       # ASBD ↔ AVAudioFormat helpers
  Storage/
    RecordingStore.swift          # Application Support paths, folder creation
    RecordingMetadata.swift       # Codable meta.json sidecar
  UI/
    MenuBarContent.swift          # SwiftUI MenuBarExtra body
  audio-pipeline.entitlements
```

`PBXFileSystemSynchronizedRootGroup` is set on `audio-pipeline/`, so subfolders become groups automatically — no pbxproj edits for new source files. Only `project.pbxproj` change is build settings (entitlements path, Info.plist keys, sandbox toggle, framework links).

## Assumptions on the table

- AudioCap-style tap setup still works on macOS 26 Tahoe. Untested by me yet; project doc claims it does.
- `AVAudioFile` with ALAC settings + float32 source processing format produces a valid `.caf` that QuickTime can play back. Standard pattern; should be safe.
- The system tap captures all output processes including the app itself. If self-capture loop becomes an issue we can pass our own PID to `CATapDescription`'s exclusion list — not relevant for first pass since we don't play audio.
- `AudioDeviceCreateIOProcIDWithBlock`'s `dispatch_queue` argument is interpreted as a hint, not a literal queue the block runs on. The block still runs on a real-time thread. Treat it as such.

## Build environment gotcha — iCloud + codesign

The repo lives under `~/Documents/`, which is iCloud-synced ("Desktop & Documents
Folders"). iCloud's file provider stamps `com.apple.FinderInfo` onto files and
folders inside that tree. `codesign` rejects bundles carrying `FinderInfo`
("resource fork, Finder information, or similar detritus not allowed"), so a
build whose DerivedData lands inside the repo fails at the CodeSign step even
though compile + link succeed.

Fix: keep DerivedData outside the iCloud tree. From the sandboxed Claude Code
session, `/tmp` is writable and not iCloud-managed — build with
`-derivedDataPath /tmp/ap-build`. Opening the project in Xcode and using ⌘R also
works, because Xcode's default DerivedData is `~/Library/Developer/Xcode/...`,
which is not iCloud-synced.

## Smoke test for this pass

1. Build Debug (DerivedData outside iCloud — see gotcha above).
2. Run the app from Xcode (or `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`).
3. macOS prompts for microphone access — grant it.
4. macOS may prompt for system-audio capture (TCC) — grant it.
5. Play something on the Mac (YouTube, music) and say something into the mic.
6. Stop recording from menu bar.
7. Open recordings folder. Confirm:
   - timestamped folder exists
   - `mic.caf` plays back with the user's voice
   - `system.caf` plays back with the system audio
   - `meta.json` has start, stop, durations, sample rates

If any of those fail, the next pass is debugging, not feature work.

## What I'd reach for next, in priority order

1. Verify smoke test actually works (manual run by Miklos).
2. If sandbox off bothers us, flip it back on and retest.
3. Input device picker in a Settings window.
4. Idle CPU/RAM measurement under Instruments.
5. Pause/resume.
6. Global hotkey (Carbon).
7. Per-recording notes field.
