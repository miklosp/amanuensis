---
title: Test coverage — design
status: draft
created: 2026-05-22
owner: Miklos
---

# Test coverage — design

## 1. Context & goal

The app has grown from the Xcode template into a working menu-bar recorder
(~1300 lines, 15 Swift files) with no automated tests and no test target.
The goal: exhaustive automated coverage of everything deterministic, plus the
minimum production-code refactor needed to make the recording lifecycle
testable.

"Exhaustive" has a hard ceiling. `MicRecorder`, `ProcessTapRecorder`,
`AudioCapturePermission`, and `RecordingSession` drive Core Audio process taps,
`AVAudioEngine`, and the private TCC SPI. They need a real input device, a
default output device, the audio-capture grant, and macOS 14.4+. They cannot
run headless in CI and are out of scope for automated tests — they get a
documented manual smoke test instead (§6).

## 2. Decisions

- **D1 — Framework: Swift Testing.** Xcode 26 default for new targets;
  `@Test(arguments:)` parameterization suits the state-machine transition
  matrix. No XCTest, no XCUITest.
- **D2 — Scope: logic + testability refactor.** Test all deterministic logic;
  refactor the recording lifecycle so its decision logic becomes a pure,
  fully testable value type.
- **D3 — Refactor shape: extract a pure state machine (Approach C).** Pull the
  lifecycle decision logic out of `AppCoordinator` into a pure value-type state
  machine (`RecorderStateMachine`). `AppCoordinator` becomes a thin driver that
  only executes effects. Follows the `swift-state-machine` skill: enum state
  with per-phase data, pure action-returning transitions, side effects executed
  by the driver outside the transition.
- **D4 — No protocol/DI injection.** Because all testable logic moves into the
  state machine and two pure helpers, the driver's remaining code is a
  mechanical "run one effect, feed the result back" loop with nothing to assert
  that the machine tests don't already cover. The driver constructs
  `RecordingSession` / `RecordingStore` / `FLACExporter` directly; it is
  untested by design and falls under the §6 hardware boundary. This is strictly
  less code than introducing capture-layer protocols.
- **D5 — Behaviour is preserved exactly.** The refactor is structural. No
  observable behaviour changes; quirks are documented (§7), not fixed.

## 3. The refactor

Three pure types are extracted. `AppCoordinator` becomes a driver.

### 3.1 `RecorderStateMachine` (new — `Audio/RecorderStateMachine.swift`)

A pure value-type `struct`. State is an enum with per-phase structs; transition
methods are pure (mutate state, return a typed `Action`); the driver executes
actions.

```
struct RecorderStateMachine {
    enum Phase: Equatable {
        case idle
        case starting(Starting)     // folder: RecordingFolder?  (nil until created)
        case recording(Recording)   // folder: RecordingFolder
        case stopping(Stopping)     // folder: RecordingFolder
    }

    enum Action: Equatable {
        case requestMicPermission
        case requestSystemPermission
        case createFolder
        case startSession(RecordingFolder)
        case stopSession
        case convertOutput(RecordingFolder)
        case refreshLibrary
        case none      // valid transition, no driver effect
        case ignore    // event not applicable in this phase; no state change
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var lastFolderURL: URL?
}
```

Cross-cutting display history (`lastError`, `lastFolderURL`) lives as machine
fields, not inside a phase — it is valid in every phase.

**Events** (pure mutating methods, each returns one `Action`):
`start()`, `micPermissionResolved(granted:)`, `systemPermissionResolved()`,
`folderCreated(_:Result<RecordingFolder,Error>)`,
`sessionStarted(_:Result<Void,Error>)`, `stop()`, `sessionStopped()`,
`conversionFinished(_:Result<Void,Error>)`.

**Query properties:** `isRecording`, `isBusy` (true in `.starting`/`.stopping`),
`statusText` (absorbs `MenuBarContent.statusLine`: `"Idle"`, `"Starting…"`,
`"Recording: <name>"`, `"Stopping…"`).

**Full transition table.** Any event not listed for a phase returns `.ignore`
with no state change.

| Phase | Event | → Phase | Action | Side effect on fields |
|---|---|---|---|---|
| idle | `start()` | starting(folder: nil) | `.requestMicPermission` | `lastError = nil` |
| starting | `micPermissionResolved(true)` | starting | `.requestSystemPermission` | — |
| starting | `micPermissionResolved(false)` | idle | `.none` | `lastError =` mic-denied message |
| starting | `systemPermissionResolved()` | starting | `.createFolder` | — |
| starting | `folderCreated(.success(f))` | starting(folder: f) | `.startSession(f)` | — |
| starting | `folderCreated(.failure(e))` | idle | `.none` | `lastError = "Couldn't create recording folder: …"` |
| starting(folder: f) | `sessionStarted(.success)` | recording(f) | `.none` | — |
| starting(folder: f) | `sessionStarted(.failure(e))` | idle | `.none` | `lastError = "Couldn't start recording: …"` |
| recording(f) | `stop()` | stopping(f) | `.stopSession` | — |
| stopping(f) | `sessionStopped()` | idle | `.convertOutput(f)` | `lastFolderURL = f.url` |
| any | `conversionFinished(.success)` | unchanged | `.refreshLibrary` | — |
| any | `conversionFinished(.failure(e))` | unchanged | `.refreshLibrary` | `lastError = "FLAC conversion failed: …"` |

Mic-denied message string is preserved verbatim from the current
`AppCoordinator`. Out-of-phase events (e.g. `stop()` while idle,
`micPermissionResolved` while recording) return `.ignore`.

### 3.2 `OutputConversionPlanner` (new — `Audio/OutputConversionPlanner.swift`)

Pure helper capturing `runOutputConversion`'s decision tree.

```
struct ConversionTask: Equatable {
    let source: URL              // .caf to convert
    let destination: URL         // .flac to write
    let deleteSourceAfterExport: Bool
}

enum OutputConversionPlanner {
    static func plan(format: AppSettings.OutputFormat,
                     folder: RecordingFolder) -> [ConversionTask]
}
```

- `.caf` → `[]` (no conversion).
- `.flac` → two tasks (mic, system), `deleteSourceAfterExport == true`.
- `.both` → two tasks (mic, system), `deleteSourceAfterExport == false`.

The file-exists check and the real `FLACExporter.export` call stay in the
driver — the planner is pure.

### 3.3 `RecordingFormatters` (new — `UI/RecordingFormatters.swift`)

`durationText(_:Double?) -> String` and `sizeText(_:Int64) -> String`, lifted
verbatim from `RecordingsView`'s `private static` helpers. `RecordingsView`
calls into this type instead.

### 3.4 `AppCoordinator` as driver

`AppCoordinator` keeps `private var machine: RecorderStateMachine` (a stored
value-type property — mutation is observed, so `@Observable` still works).
Public surface becomes computed pass-throughs: `statusText`, `isRecording`,
`isBusy`, `lastError`, `lastFolderURL`. The `Status` enum is removed (replaced
by `RecorderStateMachine.Phase`).

The driver has one effect runner — `run(_ action:) async` — that executes a
single action, feeds the resulting event back into the machine, and recurses on
the next action:

- `.requestMicPermission` → `await MicRecorder.requestPermissionIfNeeded()` →
  `machine.micPermissionResolved(granted:)`
- `.requestSystemPermission` → `await AudioCapturePermission.requestIfNeeded()`
  (driver logs a non-grant) → `machine.systemPermissionResolved()`
- `.createFolder` → `RecordingStore(...).makeRecordingFolder(...)` →
  `machine.folderCreated(_:)`
- `.startSession(f)` → construct + `start()` a `RecordingSession`, retain it →
  `machine.sessionStarted(_:)`
- `.stopSession` → `session.stop()`, release it → `machine.sessionStopped()`
- `.convertOutput(f)` → run `OutputConversionPlanner.plan(...)`, for each task
  whose source exists call `FLACExporter.export` (delete source if flagged) →
  `machine.conversionFinished(_:)`
- `.refreshLibrary` → `library.refresh()`
- `.none`, `.ignore` → stop.

`MenuBarContent` is updated: `statusLine` is replaced by
`Text(coordinator.statusText)`; the removed `Status` enum is no longer
referenced.

### 3.5 Supporting conformance changes

Small additions required by the extracted types and their tests:

- `RecordingFolder: Equatable` (so `Action`/`Phase` are `Equatable`).
- `RecordingMetadata` and `RecordingMetadata.TrackMetadata`: `Equatable` (so the
  Codable round-trip test can assert with `#expect(a == b)`).

## 4. Test inventory

All cases below run headless: no microphone, no system-audio grant, no network.

### 4.1 `RecorderStateMachineTests` — pure, no I/O

The core of the suite. Covers every cell of the §3.1 transition table.

- Each valid transition: assert resulting `Phase`, returned `Action`, and
  `lastError` / `lastFolderURL`.
- Out-of-phase events for every phase: assert `.ignore` and that phase + fields
  are unchanged (parameterized over phase × event).
- `start()` clears a stale `lastError`.
- `sessionStopped()` sets `lastFolderURL` to the folder URL.
- `conversionFinished(.failure)` sets `lastError` but leaves phase untouched.
- A full happy-path sequence start → … → idle, asserting the action at each
  step.
- Query properties: `isRecording`, `isBusy`, `statusText` for all four phases.

### 4.2 `OutputConversionPlannerTests` — pure, no I/O

- `.caf` → empty plan.
- `.flac` → two tasks; correct `mic.caf`→`mic.flac` / `system.caf`→
  `system.flac` URLs; `deleteSourceAfterExport == true`.
- `.both` → two tasks; same URLs; `deleteSourceAfterExport == false`.

### 4.3 `AppSettingsTests` — injected `UserDefaults` suite

Each test uses a fresh `UserDefaults(suiteName:)`, cleared on teardown.

- First run: `recordingsDirectory == defaultRecordingsDirectory`,
  `outputFormat == .caf`.
- Setting `recordingsDirectory` persists; a new `AppSettings` on the same suite
  reads it back.
- Setting `outputFormat` persists and reloads.
- An invalid persisted `outputFormat` raw string falls back to `.caf`.
- `OutputFormat`: `id == rawValue`, `title` non-empty per case, `allCases`
  covers `caf`/`flac`/`both`.

### 4.4 `RecordingStoreTests` — temp directory

- `makeRecordingFolder(label: nil, date:)` with a fixed date → `name` is
  ISO-8601 with `:` stripped; the directory is actually created.
- `label: "a/b"` → `/` replaced with `-` in the name.
- `label: ""` → treated as no label.
- `RecordingFolder` URL helpers (`micURL`, `systemURL`, `metadataURL`) resolve
  to the expected file names.

### 4.5 `RecordingMetadataTests` — pure + temp directory

- Codable round-trip: encode → decode → `Equatable` equal, with ISO-8601 dates
  and both optional and present `mic`/`system`/`stoppedAt`.
- `schemaVersion` defaults to `1`.
- `write(to:)` to a temp URL, re-read, equal.

### 4.6 `RecordingItemTests` — temp fixtures

Fixture = a temp folder with a written `meta.json` plus dummy track files of
known sizes.

- Valid fixture → non-nil; `name`, `startedAt`, `duration` from metadata.
- Missing `meta.json` → `nil`.
- Corrupt `meta.json` → `nil`.
- `sizeBytes` sums all files in the folder.
- `formatSummary`: `"caf"`, `"flac"`, `"caf + flac"`, `""` for the four file
  combinations.

### 4.7 `RecordingsLibraryTests` — injected settings → temp directory

`AppSettings` on a throwaway suite with `recordingsDirectory` pointed at a temp
dir.

- `refresh()` lists valid recording folders sorted newest-first.
- Non-directory entries and folders without `meta.json` are skipped.
- Missing recordings directory → `recordings == []`.
- `delete(_:)` removes the folder from disk (moved to Trash) and refreshes the
  list. (Note: this leaves one recoverable item in the user Trash per run —
  acceptable for a throwaway temp folder.)

### 4.8 `RecordingFormattersTests` — pure

- `durationText(nil)` → `"—"`; rounding; `m:ss` zero-padding (e.g. `65` →
  `"1:05"`).
- `sizeText` produces the expected `ByteCountFormatter` output for sample byte
  counts.

### 4.9 `AudioFileWriterTests` — synthetic audio, no hardware

Construct an `AVAudioFormat` directly; build `AVAudioPCMBuffer`s in-test.

- Enqueue N buffers of known `frameLength` → `close()` → `framesWritten`
  equals the sum; the output `.caf` opens with `AVAudioFile(forReading:)` at
  the expected length.
- Enqueue after `close()` is a no-op (frame count unchanged).
- Double `close()` is safe and returns a stable count.

### 4.10 `FLACExporterTests` — synthetic audio, no hardware

Synthesize a 48 kHz stereo `.caf` in-test, then export.

- Output opens readable at 16 kHz, mono; length ≈ input length / 3.
- Empty-input `.caf` → export completes without crashing, output readable.
- Very-short input (e.g. 10 frames) → export completes without crashing.

These exercise the `commonFormat` / `AVAudioFile.write` path that crashed
before commit `e775746`; running export to completion is the regression guard.
Bit-depth (16-bit) is asserted best-effort from the output `fileFormat`.

## 5. Test infrastructure

**Target.** A new Swift Testing unit-test target, `audio-pipelineTests`, with
`@testable import audio_pipeline`. It sets `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` to match the app target, so suites are implicitly `MainActor` and
need no isolation ceremony. See §9 for the creation prerequisite.

**File layout** (mirrors the source tree):

```
audio-pipelineTests/
  RecorderStateMachineTests.swift
  OutputConversionPlannerTests.swift
  AppSettingsTests.swift
  RecordingStoreTests.swift
  RecordingMetadataTests.swift
  RecordingItemTests.swift
  RecordingsLibraryTests.swift
  RecordingFormattersTests.swift
  AudioFileWriterTests.swift
  FLACExporterTests.swift
  Support/
    TempDirectory.swift     // make + auto-clean a unique temp dir
    SyntheticAudio.swift     // build AVAudioFormat, PCM buffers, CAF fixtures
    Fixtures.swift           // build RecordingMetadata + on-disk recording folders
```

**Helpers.**

- `TempDirectory` — creates a unique directory under `FileManager`'s temp area
  and removes it on teardown.
- `SyntheticAudio` — builds standard `AVAudioFormat`s, fills `AVAudioPCMBuffer`s
  with deterministic samples, and writes synthetic `.caf` files.
- `Fixtures` — assembles a recording folder on disk (`meta.json` + dummy track
  files) for `RecordingItem` / `RecordingsLibrary` tests.

## 6. Hardware boundary — manual smoke test

Not automated: `MicRecorder`, `ProcessTapRecorder`, `AudioCapturePermission`,
`RecordingSession`, and the `AppCoordinator` driver's real `run(_:)` against
live Core Audio. SwiftUI views (`MenuBarContent`, `RecordingsView`,
`SettingsView`) are also excluded.

Manual checklist, to be run on a Mac with a microphone before any release:

1. Launch the app; confirm it appears in the menu bar, no Dock icon.
2. Start recording; grant the microphone and system-audio prompts on first run.
3. Play audio for a few seconds, speak into the mic, stop recording.
4. Confirm a timestamped folder under the recordings directory contains
   `mic.caf`, `system.caf` (or their `.flac` per the output-format setting),
   and `meta.json`.
5. Confirm `meta.json` has plausible durations and non-zero `framesWritten`.
6. With output format `.flac`, confirm `.caf` files are removed; with `.both`,
   confirm both remain.
7. Open the Recordings window; confirm the new recording is listed with the
   right size and duration.

## 7. Behaviour-preservation notes & observations

- The refactor changes structure only; §4 success is gated on behaviour being
  identical before and after.
- **Observation (not fixed):** FLAC conversion currently runs *after* the phase
  has returned to `.idle`. A second `start()` is therefore accepted while the
  previous recording's conversion is still in flight. This is preserved exactly
  — the machine emits `.convertOutput` on the transition into `.idle`.
- **Faithful simplification:** the current `runOutputConversion` sets
  `lastError` per failed track. The driver now reports conversion as a single
  `Result`; on any track failure it surfaces one failure. The visible outcome
  (an error message shown, library refreshed) is unchanged.

## 8. Success criteria

- Every unit in §4 has the listed cases; all green under
  `xcodebuild test -project audio-pipeline.xcodeproj -scheme audio-pipeline`.
- The full automated suite runs headless — no microphone, no permissions, no
  network.
- The hardware boundary (§6) is documented, so "what is untested and why" is
  unambiguous.
- The app builds and behaves identically to before the refactor (§6 smoke test
  passes).

## 9. Out of scope

- Automated tests for the Core Audio / `AVAudioEngine` / TCC primitives.
- XCUITest / SwiftUI view tests.
- Performance, fuzz, and concurrency-stress testing.
- Any behaviour change to the recording pipeline.

## 10. Prerequisite — test target creation

The test target does not exist, and the project's CLAUDE.md forbids
hand-editing `project.pbxproj`. **Decision: Claude creates it programmatically
via the `xcodeproj` Ruby gem** — supported tooling, not hand-editing. The
implementation plan's first step adds an `audio-pipelineTests` Swift Testing
unit-test target via a committed `xcodeproj` script, configured to `@testable
import audio_pipeline` and to match the app target's
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. New test files land in a
synchronized group so they are auto-discovered, consistent with the app's
existing `PBXFileSystemSynchronizedRootGroup` setup.
