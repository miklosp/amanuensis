---
title: Test coverage — design
status: draft
created: 2026-05-22
revised: 2026-05-25
owner: Miklos
---

# Test coverage — design

## 1. Context & goal

The app is a working menu-bar recorder (~1600 lines across the app target + the
local SPM umbrella package at `Packages/AudioPipeline/`). M1 (menu-bar capture
+ FLAC conversion) is complete, and the source has already been split into
three SPM modules: `AppSettings`, `RecordingStorage`, `RecordingCore`. The app
target retains UI, `AppCoordinator`, and the app entry point.

Existing test surfaces are scaffolded but empty:

- **App-hosted XCTest** (`audio-pipelineTests/`) — one placeholder smoke
  asserting the test target links the app module.
- **SPM tests** (`Packages/AudioPipeline/Tests/{AppSettings,RecordingStorage,
  RecordingCore}Tests/`) — one placeholder smoke per module, each asserting the
  module compiles into a test target.

The goal: exhaustive automated coverage of everything deterministic, plus the
minimum production-code refactor needed to make the recording lifecycle
testable. The five placeholder smoke tests get replaced by the real inventory
in §4.

"Exhaustive" has a hard ceiling. `MicRecorder`, `ProcessTapRecorder`,
`AudioCapturePermission`, `MicrophonePermission`, and `RecordingSession` drive
Core Audio process taps, `AVAudioEngine`, and the private TCC SPI. They need a
real input device, a default output device, the audio-capture grant, and
macOS 14.4+. They cannot run headless in CI and are out of scope for
automated tests — they get a documented manual smoke test instead (§6).

## 2. Decisions

- **D1 — Framework: Swift Testing.** Xcode 26 default; `@Test(arguments:)`
  parameterization suits the state-machine transition matrix. Used in both
  SPM test targets and the app-hosted `audio-pipelineTests`. No XCTest,
  no XCUITest.
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
- **D6 — Three test surfaces, prefer SPM.** SPM tests run inside the Claude
  Code sandbox without policy widening (`swift test --disable-sandbox`).
  App-hosted XCTest currently hits a codesign-in-nested-sandbox blocker
  documented in [[project_xcodebuild_test_sandbox]]. Place each test on the
  surface that can host its subject; only the app-hosted surface needs the
  sandbox widening, and only the driver/UI-formatter tests need that surface.
- **D7 — Refactor placements:** `RecorderStateMachine` lands in `RecordingCore`
  (pure type, sandbox-testable via `@testable import RecordingCore`).
  `OutputConversionPlanner` and `RecordingFormatters` are app-target-only
  helpers (post-recording orchestration + UI formatting) — they live next to
  `AppCoordinator` / under `UI/`, and their tests run app-hosted alongside
  the driver tests that need the same surface anyway.

## 3. The refactor

Three pure types are extracted. `AppCoordinator` becomes a driver.

### 3.1 `RecorderStateMachine` — `Packages/AudioPipeline/Sources/RecordingCore/RecorderStateMachine.swift`

A pure value-type `public struct`. State is an enum with per-phase structs;
transition methods are pure (mutate state, return a typed `Action`); the driver
executes actions.

```
public struct RecorderStateMachine {
    public enum Phase: Equatable {
        case idle
        case starting
        case recording(folderName: String, folderURL: URL)
        case stopping
    }

    public enum Action: Equatable {
        case none
        case requestPermissionsAndStart
        case startSession                       // perms granted, folder ready
        case stopSession                        // user requested stop
        case convertOutput(folderURL: URL)      // session has stopped
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastError: String?
    public private(set) var lastFolderURL: URL?

    public init() {}

    // Events — pure mutating transitions returning the next Action.
    public mutating func start() -> Action
    public mutating func permissionsResolved(micGranted: Bool) -> Action
    public mutating func folderReady(name: String, url: URL) -> Action
    public mutating func sessionStarted() -> Action
    public mutating func sessionFailed(_ error: String) -> Action
    public mutating func stop() -> Action
    public mutating func sessionStopped(folderURL: URL) -> Action
    public mutating func conversionFinished(_ result: Result<Void, Error>) -> Action

    // Query properties used by the menu bar.
    public var isRecording: Bool { … }
    public var isBusy: Bool { … }
    public var statusText: String { … }
}
```

The transition matrix is the test surface — every cell of (phase × event) →
(next phase, action, side fields) is asserted in §4.1. The machine is pure: no
I/O, no Core Audio, no `AppSettings`, no `RecordingFolder`. URLs and names are
opaque payloads carried through.

Visibility: `public` because tests live in a separate SPM target
(`RecordingCoreTests`). Implementation details (e.g. private helpers) stay
`internal`/`private`.

### 3.2 `OutputConversionPlanner` — `audio-pipeline/OutputConversionPlanner.swift`

A pure value type. Takes a `RecordingFolder` and an `OutputFormat`; returns a
list of conversion tasks the driver will execute. Lives in the app target
because conversion is post-recording orchestration, not part of the recording
domain — `RecordingCore` stays dep-free from `AppSettings`.

```
enum OutputConversionPlanner {
    struct Task: Equatable {
        let source: URL                   // existing .caf
        let destination: URL              // .flac to be produced
        let deleteSourceAfterExport: Bool
    }

    static func plan(
        folder: RecordingFolder,
        format: AppSettings.OutputFormat
    ) -> [Task]
}
```

- `.caf` → empty plan (nothing to do).
- `.flac` → one task per existing track (`mic.caf` → `mic.flac`,
  `system.caf` → `system.flac`), `deleteSourceAfterExport == true`.
- `.both` → same URLs, `deleteSourceAfterExport == false`.

Internal visibility — the app target consumes it directly.

### 3.3 `RecordingFormatters` — `audio-pipeline/UI/RecordingFormatters.swift`

Pure formatting helpers currently inlined as `private static` methods on
`RecordingsView` (`durationText`, `sizeText`). Extract as a free-standing enum
so they're tested without instantiating a SwiftUI view.

```
enum RecordingFormatters {
    static func durationText(_ seconds: Double?) -> String
    static func sizeText(_ bytes: Int64) -> String
}
```

`RecordingsView` switches from `Self.durationText(...)` to
`RecordingFormatters.durationText(...)`.

### 3.4 `AppCoordinator` as driver

`AppCoordinator` becomes a thin driver around a `RecorderStateMachine`. The
existing `status`/`lastError`/`lastFolderURL` properties remain on the
coordinator and are derived from the machine's state. Public surface is
unchanged so callers (`MenuBarContent`, `audio_pipelineApp`) need no edits.

Internally, every UI action (`toggleRecording`, the conversion completion path)
becomes:

```
let action = machine.<event>(...)
await run(action)
```

`run(_:)` switches on `Action` and performs the effect (request permissions,
make folder, start/stop `RecordingSession`, run `OutputConversionPlanner` →
`FLACExporter`), feeding the result back via the next event.

Driver code is not unit-tested. It is exercised by the §6 manual smoke test
and (incidentally) by any app-hosted XCTest written for the conversion
planner / UI formatters.

### 3.5 Supporting visibility/conformance changes

- `RecorderStateMachine`, `Phase`, `Action` — `public`, `Equatable`. Required
  because tests live in `RecordingCoreTests` and parameterized cases compare
  states.
- `RecordingFolder` (in `RecordingStorage`) — already `public`. Add a
  `nonisolated public init` that takes URL + name + startedAt, if the existing
  initializer is internal. Needed so test fixtures can construct one without
  going through `RecordingStore`.
- `RecordingMetadata` — already `public Sendable`. Verify `Equatable` is
  derivable from its `Codable` conformance; if not, add it explicitly.
- `AudioFileWriter` — stays `internal`. Tests use `@testable import
  RecordingCore`. No public-API expansion.
- `OutputConversionPlanner.Task` — `internal Equatable`. Tests live in the same
  module (app target).

## 4. Test inventory

All cases below run headless: no microphone, no system-audio grant, no network.
Each subsection labels its host target.

### 4.1 `RecorderStateMachineTests` — `RecordingCoreTests` (SPM)

`@testable import RecordingCore`. The core of the suite. Covers every cell of
the §3.1 transition table.

- Each valid transition: assert resulting `Phase`, returned `Action`, and
  `lastError` / `lastFolderURL`.
- Out-of-phase events for every phase: assert `.none` and that phase + fields
  are unchanged (parameterized over phase × event).
- `start()` clears a stale `lastError`.
- `sessionStopped()` sets `lastFolderURL` to the folder URL.
- `conversionFinished(.failure)` sets `lastError` but leaves phase untouched.
- A full happy-path sequence start → … → idle, asserting the action at each
  step.
- Query properties: `isRecording`, `isBusy`, `statusText` for all four phases.

### 4.2 `OutputConversionPlannerTests` — `audio-pipelineTests` (app-hosted)

`@testable import audio_pipeline`. Fixture folder built in a temp directory.

- `.caf` → empty plan.
- `.flac` → two tasks; correct `mic.caf`→`mic.flac` / `system.caf`→
  `system.flac` URLs; `deleteSourceAfterExport == true`.
- `.both` → two tasks; same URLs; `deleteSourceAfterExport == false`.
- Folder containing only one of mic/system → plan reflects only the
  existing track (planner skips missing sources).

### 4.3 `AppSettingsTests` — `AppSettingsTests` (SPM)

`import AppSettings`. Each test uses a fresh `UserDefaults(suiteName:)`,
cleared on teardown.

- First run: `recordingsDirectory == defaultRecordingsDirectory`,
  `outputFormat == .caf`.
- Setting `recordingsDirectory` persists; a new `AppSettings` on the same suite
  reads it back.
- Setting `outputFormat` persists and reloads.
- An invalid persisted `outputFormat` raw string falls back to `.caf`.
- `OutputFormat`: `id == rawValue`, `title` non-empty per case, `allCases`
  covers `caf`/`flac`/`both`.

### 4.4 `RecordingStoreTests` — `RecordingStorageTests` (SPM)

`import RecordingStorage`. Temp directory per test.

- `makeRecordingFolder(label: nil, date:)` with a fixed date → `name` is
  ISO-8601 with `:` stripped; the directory is actually created.
- `label: "a/b"` → `/` replaced with `-` in the name.
- `label: ""` → treated as no label.
- `RecordingFolder` URL helpers (`micURL`, `systemURL`, `metadataURL`) resolve
  to the expected file names.

### 4.5 `RecordingMetadataTests` — `RecordingStorageTests` (SPM)

`import RecordingStorage`. Pure + temp directory.

- Codable round-trip: encode → decode → equal, with ISO-8601 dates and both
  optional and present `mic`/`system`/`stoppedAt`.
- `schemaVersion` defaults to `1`.
- `write(to:)` to a temp URL, re-read, equal.

### 4.6 `RecordingItemTests` — `RecordingStorageTests` (SPM)

`import RecordingStorage`. Fixture = a temp folder with a written `meta.json`
plus dummy track files of known sizes.

- Valid fixture → non-nil; `name`, `startedAt`, `duration` from metadata.
- Missing `meta.json` → `nil`.
- Corrupt `meta.json` → `nil`.
- `sizeBytes` sums all files in the folder.
- `formatSummary`: `"caf"`, `"flac"`, `"caf + flac"`, `""` for the four file
  combinations.

### 4.7 `RecordingsLibraryTests` — `RecordingStorageTests` (SPM)

`import RecordingStorage`. The current `RecordingsLibrary.init` takes a
`baseURLProvider: @MainActor () -> URL` closure (no `AppSettings` dep) — tests
pass a closure pointing at a temp directory.

- `refresh()` lists valid recording folders sorted newest-first.
- Non-directory entries and folders without `meta.json` are skipped.
- Missing recordings directory → `recordings == []`.
- `delete(_:)` removes the folder from disk (moved to Trash) and refreshes the
  list. (Note: this leaves one recoverable item in the user Trash per run —
  acceptable for a throwaway temp folder.)

### 4.8 `RecordingFormattersTests` — `audio-pipelineTests` (app-hosted)

`@testable import audio_pipeline`. Pure.

- `durationText(nil)` → `"—"`; rounding; `m:ss` zero-padding (e.g. `65` →
  `"1:05"`).
- `sizeText` produces the expected `ByteCountFormatter` output for sample byte
  counts.

### 4.9 `AudioFileWriterTests` — `RecordingCoreTests` (SPM)

`@testable import RecordingCore` (writer is internal). Construct an
`AVAudioFormat` directly; build `AVAudioPCMBuffer`s in-test.

- Enqueue N buffers of known `frameLength` → `close()` → `framesWritten`
  equals the sum; the output `.caf` opens with `AVAudioFile(forReading:)` at
  the expected length.
- Enqueue after `close()` is a no-op (frame count unchanged).
- Double `close()` is safe and returns a stable count.

### 4.10 `FLACExporterTests` — `RecordingCoreTests` (SPM)

`import RecordingCore` (exporter is public). Synthesize a 48 kHz stereo `.caf`
in-test, then export.

- Output opens readable at 16 kHz, mono; length ≈ input length / 3.
- Empty-input `.caf` → export completes without crashing, output readable.
- Very-short input (e.g. 10 frames) → export completes without crashing.

These exercise the `commonFormat` / `AVAudioFile.write` path that crashed
before commit `e775746`; running export to completion is the regression guard.
Bit-depth (16-bit) is asserted best-effort from the output `fileFormat`.

## 5. Test infrastructure

**Targets.** Two test surfaces, already scaffolded:

- SPM: `AppSettingsTests`, `RecordingStorageTests`, `RecordingCoreTests` in
  `Packages/AudioPipeline/Tests/`. Each currently holds one placeholder smoke
  test, to be replaced.
- App-hosted: `audio-pipelineTests` (Swift Testing target, created in commit
  `a465228` via `scripts/setup-tests.rb` using the `xcodeproj` Ruby gem).
  Inherits `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from the app target so
  suites are implicitly `MainActor`.

**File layout.**

```
Packages/AudioPipeline/Tests/
  AppSettingsTests/
    AppSettingsTests.swift
  RecordingStorageTests/
    RecordingStoreTests.swift
    RecordingMetadataTests.swift
    RecordingItemTests.swift
    RecordingsLibraryTests.swift
    Support/
      TempDirectory.swift
      Fixtures.swift           // RecordingMetadata + on-disk folders
  RecordingCoreTests/
    RecorderStateMachineTests.swift
    AudioFileWriterTests.swift
    FLACExporterTests.swift
    Support/
      TempDirectory.swift      // dup of the storage one — small, no shared module
      SyntheticAudio.swift     // AVAudioFormat, PCM buffers, CAF fixtures

audio-pipelineTests/
  OutputConversionPlannerTests.swift
  RecordingFormattersTests.swift
  Support/
    TempDirectory.swift        // dup again — small, app-hosted has no SPM access
    Fixtures.swift             // builds a folder with mic.caf/system.caf for the planner
```

**Helpers.**

- `TempDirectory` — creates a unique directory under `FileManager`'s temp area
  and removes it on teardown. Duplicated across `RecordingStorageTests`,
  `RecordingCoreTests`, and `audio-pipelineTests`. The duplication is
  acceptable: each is ~15 lines, and carving a "TestSupport" SPM module just to
  share three small types isn't worth the dep edge or the visibility juggling.
- `SyntheticAudio` — builds standard `AVAudioFormat`s, fills `AVAudioPCMBuffer`s
  with deterministic samples, and writes synthetic `.caf` files. Only needed
  in `RecordingCoreTests`.
- `Fixtures` — assembles a recording folder on disk (`meta.json` + dummy track
  files). Lives in both `RecordingStorageTests` and `audio-pipelineTests` (the
  planner tests need a folder with track files).

## 6. Hardware boundary — manual smoke test

Not automated: `MicRecorder`, `ProcessTapRecorder`, `AudioCapturePermission`,
`MicrophonePermission`, `RecordingSession`, and the `AppCoordinator` driver's
real `run(_:)` against live Core Audio. SwiftUI views (`MenuBarContent`,
`RecordingsView`, `SettingsView`) are also excluded.

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
- The existing SPM smoke tests at `Packages/AudioPipeline/Tests/*/SmokeTests.swift`
  and the app-hosted `audio-pipelineTests/SmokeTests.swift` are placeholders.
  They are replaced/absorbed by the real test files in §4 — no parallel
  "smoke" file remains after the inventory lands.

## 8. Success criteria

- Every unit in §4 has the listed cases.
- SPM suite green: `swift test --disable-sandbox --package-path
  Packages/AudioPipeline` runs inside the Claude Code sandbox.
- App-hosted suite green: `xcodebuild test -project audio-pipeline.xcodeproj
  -scheme audio-pipeline -derivedDataPath /tmp/audio-pipeline-build
  OTHER_SWIFT_FLAGS=-disable-sandbox`. This currently requires the
  local-overrides.sb codesign widening tracked in
  [[project_xcodebuild_test_sandbox]]; if not yet in place, run from outside
  the sandbox and read the log from `/tmp/`.
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
- Carving a shared "TestSupport" SPM module (see §5 helpers rationale).

## 10. Prerequisite — test target creation

Both test surfaces already exist:

- The app-hosted `audio-pipelineTests` was created in commit `a465228` via
  `scripts/setup-tests.rb` (the `xcodeproj` Ruby gem). The script is
  idempotent; further test files are added by dropping `.swift` files into
  `audio-pipelineTests/` — the synchronized group picks them up automatically.
- The three SPM test targets (`AppSettingsTests`, `RecordingStorageTests`,
  `RecordingCoreTests`) were created as part of the SPM migration. Adding
  new test files inside their directories needs no `Package.swift` edits.

No further target-creation work is needed. The implementation plan starts by
replacing the five placeholder smoke tests with the real inventory.
