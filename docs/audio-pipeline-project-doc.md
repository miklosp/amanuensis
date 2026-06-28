---
title: audio-pipeline — Project Documentation (Preliminary)
status: draft
created: 2026-05-20
owner: Miklos
tags: [project, macos, swift, audio, transcription]
---

# audio-pipeline

A no-nonsense macOS audio capture and processing pipeline. Records mic + system audio with minimal resource overhead, then routes recordings through user-defined pipelines (convert, transcribe, deliver) without forcing a local model, a subscription, or a cloud account on the user.

## Motivation

Existing Mac "Whisper apps" all impose constraints that get in the way:

- They require a local model download even when the user wants cloud transcription
- They lock the user into one transcription provider
- They bundle UI, recording, transcription, and delivery into a single rigid flow
- They treat the recording itself as a side effect of the transcription, so audio quality, format choice, and storage are afterthoughts
- They often need a virtual audio driver (BlackHole, Background Music) to capture system audio

This project inverts those assumptions:

1. **Recording is the product.** Transcription is one optional pipeline stage among many.
2. **No local model required.** The user picks where audio goes — cloud API, local model, plain folder, or nowhere.
3. **Pipelines are composable.** Convert, send, save, notify — each step is a node the user wires up.
4. **No virtual audio drivers.** macOS 14.4+ Core Audio process taps capture system audio natively.

## Scope and non-goals

**In scope**

- Native macOS app (Swift + SwiftUI, no Catalyst, no Electron)
- macOS 26 Tahoe target (14.4+ floor for the tap API; 26 for the audio bug fixes)
- Apple Silicon first; Intel later if trivial
- Local-first: recordings, pipeline definitions, and logs live on disk under user control
- Bring-your-own-keys for any cloud connector

**Out of scope (for now)**

- iOS / iPadOS
- Screen recording (mic + system audio only; revisit if there's demand)
- Built-in local transcription model (user can wire WhisperKit or whisper.cpp as a connector if they want)
- Multi-user / team features
- Mac App Store distribution in M1 (sandboxing complicates Core Audio taps; revisit later)

## Milestones

### M1 — Resource-efficient recorder

**Goal:** the smallest possible app that reliably records mic + system audio to a file, idles cheaply, and stays out of the way.

Success criteria:

- Captures default-output system audio via Core Audio process tap (no BlackHole, no kernel extension)
- Captures any selected input device (built-in mic, USB mic, Bluetooth) via `AVAudioEngine`
- Writes two separate tracks per session (mic + system) to one container, or two files — TBD, but separation must be preserved so downstream pipelines can process them independently
- Menu bar app, no dock icon by default
- Idle CPU < 0.5%, idle RAM < 50 MB
- Recording CPU < 5% on M-series for stereo 48 kHz capture
- Start / stop / pause from menu bar, with global hotkey
- Per-recording metadata sidecar (start time, devices used, sample rate, duration, app-level notes)
- Crash-safe: power loss mid-recording leaves a playable partial file

Out of M1 (deferred to M2): any post-processing, any network call, any pipeline UI.

### M2 — Pipeline builder

**Goal:** every finished recording lands in a queue. The user defines pipelines as ordered sequences of nodes. Recordings can be tagged with a pipeline (manually or by rule), and the queue runs them.

Success criteria:

- A recording is queued automatically on stop
- Pipelines are defined in a UI (drag/drop or list-based; TBD) and persisted as JSON or YAML on disk
- Pipelines are versioned and editable while runs are in flight (running runs use the version they started with)
- A pipeline is a DAG of nodes; M2 ships with a linear sequence and adds branching later if needed
- Each run produces a structured log (which nodes ran, durations, inputs, outputs, errors)
- Failed runs are retryable from the failing node
- All node I/O is on-disk files with explicit paths — no implicit "the output of the last node is the input of the next" magic that hides what's happening

### M3 and beyond — Connector catalogue

See [Connectors](#connectors) below. Each connector is an independent unit that can ship on its own schedule once M2 is stable.

### M4 (aspirational) — Speak-to-type dictation mode

**Goal:** a global hotkey that turns the app into a push-to-talk dictation tool. Hold the hotkey, speak, release, and the transcript is pasted into the frontmost text field of whatever app has focus.

This is a different mode than the recorder + pipeline flow: it bypasses the on-disk recording store, streams (or buffers briefly then sends) audio to a fast transcription connector, and uses macOS accessibility APIs to paste the result.

Success criteria:

- Global hotkey, configurable, push-to-talk and toggle modes
- Sub-2-second latency from release-to-paste for short utterances (cloud), sub-500ms aspiration with a fast local model
- Works in any text field via the pasteboard + simulated paste, with the user's previous pasteboard contents restored after
- Uses the same connector catalogue as the pipeline runner — dictation is just "transcribe + output.paste" with a different transport
- Optional: a tiny floating indicator showing recording state and partial transcript
- No recording is saved by default in dictation mode; an opt-in "also keep a copy in the recordings folder" toggle

Why this is M4, not sooner: it needs the connector abstraction from M2 to avoid reimplementing transcription plumbing, and a fast-path that does not hit the on-disk recording store. Worth designing the M2 connector contract with this use case in mind so the abstraction does not need to be broken later.

## Architecture sketch

### Process model

Single macOS app, two logical subsystems:

1. **Recorder** — owns the audio graph, the menu bar UI, and the local recording store. Runs all the time the app is active.
2. **Pipeline runner** — watches the recording store, picks up new files, executes pipelines. Can be paused independently of the recorder.

Both live in the same process for M1 / M2. Splitting the pipeline runner into a launchd-managed background helper is a candidate refactor later if idle cost is too high or if the user wants pipelines to keep running when the menu bar app is quit.

### Audio graph (M1)

```
[Mic input device] ──► AVAudioEngine input node ──┐
                                                  ├──► two AVAudioFile writers
[System audio] ──► CATapDescription ──► aggregate ┘
                   device IOProc
```

- Two writers, not one mixer. Mic and system stay separate on disk. Downstream pipelines can mix, diarise, or transcribe each independently.
- Default container: CAF with ALAC, since it's lossless, Apple-native, mountable as a sparse file during recording, and tolerates abrupt termination. A "convert to mp3/wav" pipeline node handles compression for upload.

### Storage layout

```
~/Music/audio-pipeline/                          # recordings — visible, user-facing, configurable
  2026-05-20T14-30-12_meeting/
    mic.caf
    system.caf
    mic.flac          # present only when output format is "flac" or "both"
    system.flac
    meta.json
    pipeline-runs/
      2026-05-20T14-35-00_transcribe-gemini/
        run.log
        transcript.md

~/Library/Application Support/audio-pipeline/     # app-internal state, not user-facing
  pipelines/
    transcribe-gemini.yaml
    archive-only.yaml
  state/
    queue.db        # SQLite
    runs.db
```

Recordings live in a visible, user-owned folder (default `~/Music/audio-pipeline/`, configurable in Settings) — they are the product, not app internals. App-internal state (the SQLite queue and history, pipeline definitions) stays in `~/Library/Application Support/audio-pipeline/`.

Recordings are folders, not files. The folder is the unit of work and the unit a pipeline operates on. This makes the model trivial: "process recording X with pipeline Y" means "create a `pipeline-runs/` subfolder, write everything there."

### Pipeline model (M2)

A pipeline is a YAML or JSON document:

```yaml
name: transcribe-and-file
on:
  recording_tag: meeting
steps:
  - id: convert
    type: audio.convert
    config:
      format: mp3
      bitrate: 64k
      source: mic+system   # mix down for upload
  - id: transcribe
    type: transcribe.gemini
    config:
      model: gemini-2.5-flash
      api_key_ref: keychain://gemini-default
      language: auto
  - id: save
    type: output.obsidian
    config:
      vault: ~/Obsidian/Notes
      folder: Meetings/Transcripts
      template: meeting-transcript.md.tmpl
```

Each step is a typed node. Type strings follow `<category>.<provider>` so the runner can dispatch and the UI can group them.

Connector contract (Swift protocol):

```swift
protocol PipelineNode {
    static var type: String { get }              // "transcribe.gemini"
    static var configSchema: NodeConfigSchema { get }
    func run(input: NodeInput, context: RunContext) async throws -> NodeOutput
}
```

`NodeInput` and `NodeOutput` are file references plus structured metadata, never raw bytes in memory. Big audio files stream through the filesystem.

### Connectors

Grouped by role. Each is implemented independently; the catalogue grows as we need them.

**Transcription**

- `transcribe.mistral` — Mistral Voxtral / future endpoints
- `transcribe.claude` — Anthropic API
- `transcribe.gemini` — Google Gemini (handles audio input natively)
- `transcribe.openai` — ChatGPT / OpenAI Whisper API
- `transcribe.openai-compatible` — generic, user supplies base URL, model name, auth header
- `transcribe.local-whisperkit` — optional, only if installed; not bundled
- `transcribe.gcp-vertex` — Vertex AI; treated as separate from gemini.com because auth and request shape differ

**Conversion / preprocessing**

- `audio.convert` — format and bitrate (ffmpeg or AVAssetExportSession; ffmpeg preferred for control)
- `audio.mix` — mix mic + system into one track with optional gain trim
- `audio.split` — voice-activity-based segmentation for long recordings
- `audio.normalize` — loudness normalisation before upload

Conversion may also be implicit: a transcription node declares the formats it accepts, and the runner inserts a conversion step if the input does not match. Explicit nodes still allowed for users who want control.

**Output / delivery**

- `output.folder` — plain folder, with filename template
- `output.paste` — paste into frontmost text field via pasteboard + simulated paste; used by dictation mode (M4)
- `output.obsidian` — write to a vault folder, with frontmatter and template
- `output.notion` — page in a database, mapping fields to properties
- `output.gdocs` — Google Docs, with OAuth
- `output.email` — SMTP or Gmail API
- `output.webhook` — POST JSON to a URL

**Triggers and rules (M2.5)**

- Tag-based: recording tagged `meeting` → pipeline `transcribe-and-file`
- Device-based: recording made with headset → pipeline X
- Manual: right-click → run pipeline Y
- No automatic action: recording sits in the queue until the user picks one

## Technical decisions and open questions

### Decided

- **Language and UI:** Swift + SwiftUI, single Xcode project, no SPM split for M1
- **Frameworks:** CoreAudio (tap), AVFoundation (mic + file), AudioToolbox (transitive), Foundation, SwiftUI, AppKit (menu bar, NSStatusItem). No third-party Swift packages in M1.
- **Tap API:** `AudioHardwareCreateProcessTap` + `CATapDescription` + private aggregate device. Reference: AudioCap by Guilherme Rambo.
- **Container:** CAF + ALAC for the on-disk master. Lossless, native, crash-tolerant.
- **Recordings location:** `~/Music/audio-pipeline/` by default, user-configurable in Settings — recordings are user-facing media, not app internals. App-internal state stays in `~/Library/Application Support/audio-pipeline/`.
- **Output format (capture-time):** a Settings option — keep the CAF/ALAC master only, a converted copy only, or both. The converted copy is per-track 16 kHz mono FLAC (`mic.flac`, `system.flac`), preserving the mic/system split for speaker attribution. Conversion runs after each recording stops. This is a capture-time convenience, separate from and not a replacement for the M2 `audio.convert` pipeline node.
- **No bundled local model, but one-click install supported.** Local model connectors (WhisperKit, whisper.cpp, Parakeet, etc.) are first-class but optional. The app ships without any model weights. When the user enables a local connector, the connector handles model download, placement, and updates itself — ideally one click in the connector's settings. This keeps the base app small and avoids forcing a multi-GB download on users who only want cloud transcription, while still making local-only workflows trivial to set up.
- **Bring-your-own-keys.** API keys stored in macOS Keychain, referenced from pipeline YAML by name (never the secret itself in the file).
- **Persistence:** SQLite for the queue and run history. Files for everything else.

### Open questions

- **One file or two on disk for mic + system?** Resolved — two separate files. The mic/system split is preserved through capture and through FLAC conversion (per-track), giving free speaker attribution downstream (mic = local user, system = everyone else).
- **Pipeline DSL format:** YAML for human editing, JSON for programmatic. Lean YAML for M2 since that's what the user will hand-edit.
- **Pipeline runner concurrency:** one run at a time globally, or one per pipeline, or unlimited? M2 ships with one at a time. Configurable later.
- **Channel layout for the system tap:** Tahoe's known multi-output-pair attenuation bug means built-in speakers and AirPods are fine but pro audio interfaces will record ~12 dB low. Document it; don't try to compensate in M1.
- **Microphone permission UX:** when to prompt. Probably on first record attempt, not at launch.
- **System audio permission:** `NSAudioCaptureUsageDescription` triggers a TCC prompt the first time the tap starts. Same approach.
- **App lifecycle:** menu bar only, or dock icon optional? Menu bar only for M1. Settings window opens on demand.
- **Update mechanism:** Sparkle for M1 self-hosted, GitHub Releases as the feed source.
- **Code signing and notarisation:** required for distribution but not for personal dev. Defer until there's something worth shipping.

## Risks

- **Apple changes the tap API.** Low risk, still current on Tahoe 26 a year after introduction, but worth tracking WWDC announcements.
- **Tahoe tap attenuation bug bites pro audio users.** Real risk; mitigate by documenting and by exposing input gain controls per recording.
- **Connector sprawl.** Each cloud API drifts. Mitigate by keeping connectors thin (HTTP + auth + format-mapping) and by having a generic OpenAI-compatible connector as the escape hatch.
- **Scope creep into a DAW or a Notion alternative.** The recorder and the pipeline runner are the product. Outputs go to other tools. Resist building a "review and edit the transcript" UI in M2.

## What this is not

- Not a real-time transcription tool. Recording finishes, then pipeline runs. Streaming is a possible M4 feature.
- Not a meeting bot. It does not join Zoom or Teams as a participant. It records the system audio of whatever the user is doing.
- Not a Whisper wrapper. Whisper-class models are one connector among many; the app works without any of them installed.
- Not a cross-platform tool. macOS only; the whole value is leveraging Apple's native audio stack without virtual drivers.

## Next steps

1. Stand up the M1 Xcode project (done — `audio-pipeline`)
2. Get system audio capture working end-to-end with AudioCap as the reference
3. Add mic capture in parallel, write to two files
4. Menu bar UI: start, stop, last recording, open folder
5. Per-recording metadata sidecar
6. Manual smoke test on a real meeting
7. Only then start M2 design
