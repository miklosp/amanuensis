# Test Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal.** Add exhaustive automated tests for every deterministic part of the app, and refactor the recording lifecycle into a pure, fully testable state machine so its decision logic is covered too.

**Architecture (from spec §3).** Three pure extractions, distributed by their natural home in the post-SPM module graph:

- `RecorderStateMachine` → `Packages/AudioPipeline/Sources/RecordingCore/` — pure state machine, sandbox-testable via SPM.
- `OutputConversionPlanner` → `audio-pipeline/` (app target, next to `AppCoordinator`) — post-recording orchestration; keeps `RecordingCore` dep-free from `AppSettings`.
- `RecordingFormatters` → `audio-pipeline/UI/` — pure UI formatters lifted out of `RecordingsView`.

`AppCoordinator` becomes a thin driver around the state machine + planner. Core Audio / `AVAudioEngine` / TCC primitives stay manual (spec §6).

**Tech stack.** Swift 6.2, macOS 26.3, Swift Testing (`import Testing`), AVFoundation. SPM tests run via `swift test`; app-hosted tests run via `xcodebuild test`. Inventory and per-test cases live in the spec; this plan owns ordering and execution.

**Spec:** `docs/superpowers/specs/2026-05-22-test-coverage-design.md`

---

## Conventions

All work happens on the existing `test-coverage` branch.

### Two test surfaces

**SPM tests** — `Packages/AudioPipeline/Tests/{AppSettings,RecordingStorage,RecordingCore}Tests/`. Sandbox-friendly. Run with:

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline
```

Filter to one target:

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline \
  --filter <SuiteOrCaseName>
```

`--disable-sandbox` is mandatory: SwiftPM's manifest compilation would otherwise call `sandbox_apply` and hit the nested-sandbox blocker. New `.swift` files dropped under `Packages/AudioPipeline/Tests/<TargetName>/` are auto-discovered — no `Package.swift` edit needed.

**App-hosted XCTest** — `audio-pipelineTests/`. Currently sandbox-blocked at codesign (see [[project_xcodebuild_test_sandbox]]). Run from outside the sandbox, writing the log to `/tmp/` so Claude can read it ([[feedback_xcodebuild_log_to_readable_path]]):

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/<SuiteName> \
  > /tmp/audio-pipeline-test.log 2>&1; echo "exit=$?"
```

Drop `-only-testing:` to run the whole bundle. The `audio-pipelineTests` target is NOT a synchronized group; new test files must be registered via `bash scripts/run-setup-tests.sh`, which is idempotent and modifies `audio-pipeline.xcodeproj/project.pbxproj`.

### Build the app (after a refactor)

```bash
xcodebuild build \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -configuration Debug \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"
```

Why these flags (from project memory): DerivedData **must** live in `/tmp` — the repo is inside iCloud-synced `~/Documents`, and a build inside that tree fails codesign. `OTHER_SWIFT_FLAGS=-disable-sandbox` is **mandatory** for any build using Swift macros (`@Observable`, `@Test`/`#expect`).

### Commit style

Conventional commits (`feat:`, `test:`, `refactor:`, `chore:`). One task = one commit. Each task ends with the exact `git add` + commit-message HEREDOC.

### Ordering rationale

Phases below are ordered so each task only depends on what came before it:

1. **Phase A — SPM tests for the existing public surface.** No production-code changes. Highest ROI; immediate sandbox-friendly green.
2. **Phase B — RecordingCore additions + tests.** Adds `RecorderStateMachine` + tests, plus `AudioFileWriter`/`FLACExporter` tests. State machine has no driver wiring yet.
3. **Phase C — AppCoordinator driver refactor.** Rewires `AppCoordinator` to drive the state machine. Manual smoke verification (no automated test added here).
4. **Phase D — App-hosted refactors + tests.** Extracts `OutputConversionPlanner` and `RecordingFormatters`, wires them in, adds their tests.
5. **Phase E — Final verification.** All suites green; manual §6 smoke; ready to merge.

Phases A and B can run sandbox-internally without policy widening. Phase D's tests need the app-hosted surface — if the local-overrides.sb codesign blocker hasn't been resolved, run those externally per the conventions above.

---

## Phase A: SPM tests for existing public surface

Pure test-writing. Each task replaces one placeholder `SmokeTests.swift` (or appends to a target) with real coverage per spec §4.

### Task A1: AppSettingsTests

**Files:**
- Delete: `Packages/AudioPipeline/Tests/AppSettingsTests/SmokeTests.swift`
- Create: `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`

**Implement:** spec §4.3 — every case listed (defaults, persistence round-trips, invalid-raw fallback, `OutputFormat` invariants). Uses `UserDefaults(suiteName:)` with a fresh suite per `@Test` and explicit cleanup. No on-disk I/O.

- [ ] **Write `AppSettingsTests.swift`** per spec §4.3.
- [ ] **Verify:**
  ```bash
  swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppSettingsTests
  ```
  Expect all cases green; the old smoke is gone.
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/AppSettingsTests/
  git commit -m "test: AppSettings — defaults, persistence, OutputFormat invariants"
  ```

### Task A2: RecordingStorageTests support helpers

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/Support/TempDirectory.swift`
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/Support/Fixtures.swift`

**`TempDirectory.swift`:** small helper struct that creates a unique directory under `FileManager.default.temporaryDirectory` on init and removes it on deinit (or via an explicit `cleanup()` if Swift Testing's lifecycle prefers it). Scope: `internal`. Used by all Storage tests.

**`Fixtures.swift`:** helpers to build:
- A `RecordingMetadata` value with sensible defaults (override-able via parameters).
- An on-disk recording folder: writes `meta.json` (from the metadata helper) plus zero-byte placeholder `mic.caf` / `system.caf` / `mic.flac` / `system.flac` files per a small `Set<String>` of extensions.

- [ ] **Implement both files.** No tests yet — these are infrastructure for A3–A6.
- [ ] **Verify the module still builds:**
  ```bash
  swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingStorageTests
  ```
  Existing placeholder smoke still passes.
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/RecordingStorageTests/Support/
  git commit -m "test(storage): add TempDirectory + Fixtures helpers"
  ```

### Task A3: RecordingStoreTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingStoreTests.swift`

**Implement:** spec §4.4. Uses `TempDirectory` from A2. Asserts naming rules (`:` stripped from timestamp, `/` in labels replaced with `-`, empty label = no label) and that `RecordingFolder` URL helpers (`micURL` / `systemURL` / `metadataURL`) resolve to the expected file names under the folder URL.

- [ ] **Write tests** per spec §4.4.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingStoreTests`
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingStoreTests.swift
  git commit -m "test(storage): RecordingStore folder naming + URL helpers"
  ```

### Task A4: RecordingMetadataTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingMetadataTests.swift`

**Implement:** spec §4.5. Codable round-trip with both optional and present fields; default `schemaVersion == 1`; `write(to:)` to a `TempDirectory` URL re-reads to an equal value.

Requires `RecordingMetadata` to be `Equatable`. If not yet derived, add it in the same commit (one-line `+ Equatable` on the struct + its nested types).

- [ ] **Write tests** per spec §4.5; add `Equatable` to `RecordingMetadata` and its nested types if needed.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingMetadataTests`
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift \
          Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingMetadataTests.swift
  git commit -m "test(storage): RecordingMetadata Codable round-trip"
  ```

### Task A5: RecordingItemTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingItemTests.swift`

**Implement:** spec §4.6. Builds folders via `Fixtures` (valid, missing meta.json, corrupt meta.json, each combination of `.caf`/`.flac` files). Asserts initializer behavior + `sizeBytes` summation + `formatSummary` strings.

- [ ] **Write tests** per spec §4.6.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingItemTests`
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingItemTests.swift
  git commit -m "test(storage): RecordingItem fixture parsing + summaries"
  ```

### Task A6: RecordingsLibraryTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingsLibraryTests.swift`

**Implement:** spec §4.7. `RecordingsLibrary.init(baseURLProvider:)` takes a closure — tests pass `{ tempDir.url }`. Cases: `refresh()` lists+sorts; non-directory entries skipped; missing meta.json skipped; missing base directory → empty; `delete(_:)` moves folder to Trash (note: one recoverable item per run is OK — temp folders are throwaway).

- [ ] **Write tests** per spec §4.7.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingsLibraryTests`
- [ ] **Commit (also remove the storage placeholder smoke):**
  ```bash
  git rm Packages/AudioPipeline/Tests/RecordingStorageTests/SmokeTests.swift
  git add Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingsLibraryTests.swift
  git commit -m "test(storage): RecordingsLibrary refresh + delete; remove smoke"
  ```

### Task A7: Storage full-suite verification

- [ ] Run the whole `RecordingStorageTests` target and confirm all of A2–A6 are green together:
  ```bash
  swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingStorageTests
  ```
- [ ] No commit (verification only).

---

## Phase B: RecordingCore — state machine + audio file tests

### Task B1: RecordingCoreTests support helpers

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/Support/TempDirectory.swift`
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/Support/SyntheticAudio.swift`

`TempDirectory.swift` is a duplicate of the storage version — small, no shared module (spec §5).

`SyntheticAudio.swift`:
- Builds canonical `AVAudioFormat`s (e.g. 48 kHz stereo float, 44.1 kHz mono float).
- Fills `AVAudioPCMBuffer`s with deterministic samples (e.g. a sine wave or a ramp).
- Writes a synthetic `.caf` file at a given URL with a given frame count + format.

- [ ] **Implement both files.**
- [ ] **Verify build:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingCoreTests` (existing placeholder still passes).
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/RecordingCoreTests/Support/
  git commit -m "test(core): add TempDirectory + SyntheticAudio helpers"
  ```

### Task B2: AudioFileWriterTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/AudioFileWriterTests.swift`

`AudioFileWriter` is `internal`, so the test file begins with `@testable import RecordingCore`.

**Implement:** spec §4.9. Enqueue N synthetic buffers → close → assert `framesWritten` sum; re-open via `AVAudioFile(forReading:)` and assert length. Post-close enqueue is a no-op; double-close is safe.

- [ ] **Write tests** per spec §4.9.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AudioFileWriterTests`
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/RecordingCoreTests/AudioFileWriterTests.swift
  git commit -m "test(core): AudioFileWriter enqueue/close/double-close"
  ```

### Task B3: FLACExporterTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/FLACExporterTests.swift`

`FLACExporter` is `public` — `import RecordingCore` is enough.

**Implement:** spec §4.10. Synthesize a 48 kHz stereo `.caf`, export, re-open; assert sample rate (16 kHz), channel count (1), and length ≈ input / 3. Repeat with empty-input and very-short-input CAFs. These exercise the path that crashed before commit `e775746`.

- [ ] **Write tests** per spec §4.10.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter FLACExporterTests`
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Tests/RecordingCoreTests/FLACExporterTests.swift
  git commit -m "test(core): FLACExporter conversion + regression guards"
  ```

### Task B4: Add `RecorderStateMachine` (no driver wiring)

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/RecorderStateMachine.swift`

**Implement:** spec §3.1 — `public struct RecorderStateMachine` with `Phase` and `Action` `public Equatable` enums; pure event-handling methods returning `Action`; `isRecording` / `isBusy` / `statusText` queries.

Important: no imports of `AppSettings` or `RecordingStorage`. URLs and folder names are opaque payloads carried by events; the machine doesn't construct `RecordingFolder` itself.

- [ ] **Implement the struct** per spec §3.1.
- [ ] **Verify build:**
  ```bash
  swift build --package-path Packages/AudioPipeline
  ```
  Plus an app build (so we catch any accidental cross-target break early):
  ```bash
  xcodebuild build -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"
  ```
- [ ] **Commit:**
  ```bash
  git add Packages/AudioPipeline/Sources/RecordingCore/RecorderStateMachine.swift
  git commit -m "feat(core): add RecorderStateMachine pure value type"
  ```

### Task B5: RecorderStateMachineTests

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/RecorderStateMachineTests.swift`

Test file uses `@testable import RecordingCore` so any future internal helpers stay testable.

**Implement:** spec §4.1 — exhaustive transition matrix (parameterize over phase × event for out-of-phase cases); happy-path sequence; query properties; `start()` clears stale `lastError`; `sessionStopped()` sets `lastFolderURL`; `conversionFinished(.failure)` sets `lastError` without changing phase.

- [ ] **Write tests** per spec §4.1.
- [ ] **Verify:** `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecorderStateMachineTests`
- [ ] **Commit (also drop the core placeholder smoke):**
  ```bash
  git rm Packages/AudioPipeline/Tests/RecordingCoreTests/SmokeTests.swift
  git add Packages/AudioPipeline/Tests/RecordingCoreTests/RecorderStateMachineTests.swift
  git commit -m "test(core): RecorderStateMachine transition matrix; remove smoke"
  ```

### Task B6: RecordingCore full-suite verification

- [ ] Run all of B2/B3/B5 together:
  ```bash
  swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingCoreTests
  ```
- [ ] No commit.

---

## Phase C: AppCoordinator driver refactor

### Task C1: Rewire `AppCoordinator` to drive `RecorderStateMachine`

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

**Implement:** spec §3.4. Replace the inlined `Status` enum with a `private var machine = RecorderStateMachine()`. Recompute the existing public properties (`status`, `lastError`, `lastFolderURL`, `isRecording`, `isBusy`) from `machine` — keeping the public surface identical so `MenuBarContent`, `audio_pipelineApp`, and `RecordingsView` don't need edits.

Replace every state mutation in `startRecording` / `stopRecording` / `runOutputConversion` with:

```swift
let action = machine.<event>(...)
await run(action)
```

where `run(_:)` switches on `Action` and performs the effect (`MicrophonePermission.requestIfNeeded()`, `AudioCapturePermission.requestIfNeeded()`, `RecordingStore.makeRecordingFolder`, `try RecordingSession(folder:)`, `session.stop()`, conversion). After each effect, feed the result back via the next event method.

Conversion stays in `runOutputConversion` for now — it's untouched by this task; Phase D extracts the planner.

- [ ] **Refactor `AppCoordinator`.**
- [ ] **Verify build:**
  ```bash
  xcodebuild build -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"
  ```
- [ ] **Manual smoke (mandatory):** launch the built `.app`, run the spec §6 checklist end-to-end. The behavioural goal of D5 — no observable change — is verified here, since there's no automated driver test.
- [ ] **Commit:**
  ```bash
  git add audio-pipeline/AppCoordinator.swift
  git commit -m "refactor(coordinator): drive RecorderStateMachine; no behaviour change"
  ```

---

## Phase D: App-target refactors + app-hosted tests

App-hosted XCTest is currently blocked by the codesign-in-nested-sandbox issue ([[project_xcodebuild_test_sandbox]]). Run these test commands from outside the Claude Code sandbox, writing logs to `/tmp/` so Claude can read them.

### Task D1: Extract `OutputConversionPlanner`, wire `AppCoordinator`

**Files:**
- Create: `audio-pipeline/OutputConversionPlanner.swift`
- Modify: `audio-pipeline/AppCoordinator.swift`

**Implement:** spec §3.2 — `enum OutputConversionPlanner` with `struct Task` and a static `plan(folder:format:)` returning `[Task]`. Internal visibility.

Modify `AppCoordinator.runOutputConversion(for:)` to:
1. Call `OutputConversionPlanner.plan(folder:, format: settings.outputFormat)`.
2. Iterate the plan; for each task, `try await FLACExporter.export(from: task.source, to: task.destination)` and conditionally remove the source.
3. On any failure, set `lastError` (one summary message, per spec §7 "Faithful simplification").

- [ ] **Implement the planner + rewire.**
- [ ] **Verify build:** `xcodebuild build … > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"`
- [ ] **Commit:**
  ```bash
  git add audio-pipeline/OutputConversionPlanner.swift audio-pipeline/AppCoordinator.swift
  git commit -m "refactor(coordinator): extract OutputConversionPlanner"
  ```

### Task D2: Extract `RecordingFormatters`, wire `RecordingsView`

**Files:**
- Create: `audio-pipeline/UI/RecordingFormatters.swift`
- Modify: `audio-pipeline/UI/RecordingsView.swift`

**Implement:** spec §3.3 — `enum RecordingFormatters` with static `durationText` and `sizeText` mirroring the current `private static` methods on `RecordingsView`. Switch the view's call sites from `Self.durationText(...)` to `RecordingFormatters.durationText(...)`.

- [ ] **Implement + rewire.**
- [ ] **Verify build:** `xcodebuild build … > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"`
- [ ] **Commit:**
  ```bash
  git add audio-pipeline/UI/RecordingFormatters.swift audio-pipeline/UI/RecordingsView.swift
  git commit -m "refactor(ui): extract RecordingFormatters out of RecordingsView"
  ```

### Task D3: App-hosted test support helpers

**Files:**
- Create: `audio-pipelineTests/Support/TempDirectory.swift`
- Create: `audio-pipelineTests/Support/Fixtures.swift`

Duplicates of the Storage-side helpers (spec §5). The Fixtures helper for app-hosted only needs the planner-fixture variant: build a recording folder containing some subset of `mic.caf` / `system.caf` for `OutputConversionPlanner` tests.

- [ ] **Implement both files.**
- [ ] **Register with the target:** `bash scripts/run-setup-tests.sh`
- [ ] **Verify build:** `xcodebuild build … > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"`
- [ ] **Commit:**
  ```bash
  git add audio-pipelineTests/Support/ audio-pipeline.xcodeproj/project.pbxproj
  git commit -m "test(app): add TempDirectory + Fixtures helpers"
  ```

### Task D4: OutputConversionPlannerTests

**Files:**
- Create: `audio-pipelineTests/OutputConversionPlannerTests.swift`

`@testable import audio_pipeline`. **Implement:** spec §4.2 — empty plan for `.caf`; two-task plans for `.flac` (delete=true) and `.both` (delete=false); single-task plan when only one of `mic.caf` / `system.caf` exists.

- [ ] **Write tests.**
- [ ] **Register:** `bash scripts/run-setup-tests.sh`
- [ ] **Verify (externally):**
  ```bash
  xcodebuild test \
    -project audio-pipeline.xcodeproj \
    -scheme audio-pipeline \
    -destination 'platform=macOS' \
    -derivedDataPath /tmp/audio-pipeline-build \
    OTHER_SWIFT_FLAGS=-disable-sandbox \
    -only-testing:audio-pipelineTests/OutputConversionPlannerTests \
    > /tmp/audio-pipeline-test.log 2>&1; echo "exit=$?"
  ```
- [ ] **Commit:**
  ```bash
  git add audio-pipelineTests/OutputConversionPlannerTests.swift audio-pipeline.xcodeproj/project.pbxproj
  git commit -m "test(app): OutputConversionPlanner plan generation"
  ```

### Task D5: RecordingFormattersTests

**Files:**
- Create: `audio-pipelineTests/RecordingFormattersTests.swift`

`@testable import audio_pipeline`. **Implement:** spec §4.8 — `durationText(nil)` → `"—"`; rounding; `m:ss` zero-padding; `sizeText` matches `ByteCountFormatter.string(fromByteCount:countStyle:.file)` for sample byte counts.

- [ ] **Write tests.**
- [ ] **Register:** `bash scripts/run-setup-tests.sh`
- [ ] **Verify (externally):** as in D4, with `-only-testing:audio-pipelineTests/RecordingFormattersTests`.
- [ ] **Commit:**
  ```bash
  git add audio-pipelineTests/RecordingFormattersTests.swift audio-pipeline.xcodeproj/project.pbxproj
  git commit -m "test(app): RecordingFormatters duration + size"
  ```

### Task D6: Remove app-hosted placeholder smoke

**Files:**
- Delete: `audio-pipelineTests/SmokeTests.swift`

The original wiring smoke is redundant once D4/D5 exist.

- [ ] **Delete the file; re-run `bash scripts/run-setup-tests.sh` to drop it from pbxproj.**
- [ ] **Verify full app-hosted bundle (externally):**
  ```bash
  xcodebuild test -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox > /tmp/audio-pipeline-test.log 2>&1; echo "exit=$?"
  ```
- [ ] **Commit:**
  ```bash
  git rm audio-pipelineTests/SmokeTests.swift
  git add audio-pipeline.xcodeproj/project.pbxproj
  git commit -m "test(app): remove placeholder smoke"
  ```

---

## Phase E: Final verification

- [ ] **Full SPM suite:**
  ```bash
  swift test --disable-sandbox --package-path Packages/AudioPipeline
  ```
  Expect every test target listed in spec §5 green.
- [ ] **Full app-hosted bundle (externally):**
  ```bash
  xcodebuild test -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox > /tmp/audio-pipeline-test.log 2>&1; echo "exit=$?"
  ```
- [ ] **App build still clean:**
  ```bash
  xcodebuild build -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox > /tmp/audio-pipeline-build.log 2>&1; echo "exit=$?"
  ```
- [ ] **Manual smoke per spec §6.** Launch the built `.app`, run the full checklist. Confirm no observable change from pre-refactor behaviour.
- [ ] **Push and open PR:**
  ```bash
  git push origin test-coverage
  gh pr create --base main --title "test coverage: SPM + app-hosted suites, lifecycle state machine" --body "..."
  ```

---

## Out-of-band: app-hosted XCTest sandbox blocker

If Phase D runs while the codesign-in-nested-sandbox issue is still active, the `xcodebuild test` calls above will fail under Claude Code. Two paths:

1. **Run externally** (preferred for one-off verification): the conventions section's external command pattern works.
2. **Widen `~/.config/agent-safehouse/local-overrides.sb`** with the codesign-on-DerivedData grants needed for app-hosted test bundles. The blocker analysis is in [[project_xcodebuild_test_sandbox]] (see the 2026-05-23 follow-up). Until that's resolved, Phase D's verifications are external-only.

This does not block Phases A–C, which are all SPM-target.
