---
title: SPM module architecture — design
status: draft
created: 2026-05-24
owner: Miklos
---

# SPM module architecture — design

## 1. Context & goal

The app has grown past the "no SPM split for M1" decision recorded in
`audio-pipeline-project-doc.md`. M1 is functionally complete (~1300 lines, 15
Swift files, all in the app target) and the project is about to start writing
exhaustive automated tests against it.

The driving constraint: `xcodebuild test` against the app-hosted
`audio-pipelineTests` Xcode target cannot run inside the safehouse sandbox.
The blocker is codesigning the test runner inside a nested App Sandbox
container (`project_xcodebuild_test_sandbox.md`). The only path that combines
autonomous in-sandbox test execution, no per-command bypass, and no
test-target entitlement compromise is to put deterministic test code in SPM
modules and run those tests via `swift test`.

That fix also aligns with the long-term shape of the project: a recorder
core with composable connectors (M2/M3) and a future dictation mode (M4)
whose local-engine flavor uses MLX-Swift. Each connector and each dictation
engine is a discrete unit. Modular Swift packages are the standard pattern
for that shape.

Goal: introduce the SPM-modularized layout now, migrate the existing M1 code
into it, and leave clear seams where M2/M3/M4 modules will plug in.

Non-goal: building any M2/M3/M4 code. This is structural — recorder core
behavior is unchanged.

## 2. Decisions

- **D1 — Connector model: first-party, statically linked, each its own SPM
  module.** No third-party plugin loading. No dynamic bundles for connectors.
  Anti-pattern explicitly avoided: a single `Connectors` umbrella module that
  would force every consumer to compile every connector.
- **D2 — Package topology: single umbrella package.** `Packages/AudioPipeline/`
  with multiple library products. Matches the dominant 2025-2026 pattern
  (isowords, Apple's Backyard Birds). Multiple top-level packages are
  reserved for independently-versioned/published libraries; not our case.
- **D3 — App target imports library products directly.** No umbrella
  re-export library. `@_exported import` hides the dependency graph and was
  explicitly flagged as an anti-pattern in the research pass.
- **D4 — Per-target isolation defaults.** `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor` does NOT propagate from the app target to SPM packages (SE-0466,
  Holly Borla on Swift Forums). Each target opts in via
  `swiftSettings: [.defaultIsolation(MainActor.self), …]`. The `RecordingCore`
  target deliberately does NOT opt in — Core Audio IOProc callbacks must stay
  `nonisolated`.
- **D5 — Tests live inside each package.** Swift Testing, run via
  `swift test`. The app-hosted `audio-pipelineTests` Xcode target stays alive
  for the integration carve-out (Core Audio tap, real mic, TCC flow) that
  genuinely needs an app host.
- **D6 — Migrate M1 code now, not just scaffold for M2.** All existing M1
  files (`Audio/`, `Storage/`, `Settings/` subfolders) move into the umbrella
  package. The app target shrinks to UI + composition root.
- **D7 — Local-MLX dictation engine (M4) is a separately-codesigned satellite
  bundle, downloaded by the main app at runtime.** MLX-Swift is NOT a
  dependency of the umbrella package. The satellite is a sibling Xcode
  project, not a library product. Out of scope for this migration; design
  reserves the seam.

## 3. Module layout

Three modules in the umbrella package at migration time. No speculative
modules for unbuilt features.

| Module | Purpose | Depends on | Default isolation |
|---|---|---|---|
| `AppSettings` | User preferences (recordings dir, output format). `@Observable` for UI binding. | Foundation | `MainActor` |
| `RecordingStorage` | Folder layout under `~/Music/audio-pipeline/`, metadata sidecars, library indexing. Pure file/URL work. | Foundation | `MainActor` (`@Observable` library API drives this; file I/O helpers opt out with `nonisolated`) |
| `RecordingCore` | Audio capture (`AVAudioEngine` mic, Core Audio system tap), file writers, FLAC conversion at stop, recording lifecycle/state machine. | `RecordingStorage`, AVFoundation, AudioToolbox, CoreAudio, os.Logger | `nonisolated` (Core Audio callbacks require this) |

**File assignments:**

- `AppSettings`: `AppSettings.swift`
- `RecordingStorage`: `RecordingMetadata.swift`, `RecordingsLibrary.swift`,
  `RecordingStore.swift` (which also contains `RecordingFolder`)
- `RecordingCore`: `AudioCapturePermission.swift`, `AudioFileWriter.swift`,
  `FLACExporter.swift`, `MicRecorder.swift`, `ProcessTapRecorder.swift`,
  `RecordingSession.swift`. The `RecorderStateMachine` and
  `OutputConversionPlanner` planned by the test-coverage spec are new files
  created in this module during migration.

**Dependency graph:** `RecordingCore` → `RecordingStorage`; `AppSettings` is a
leaf. No cycles.

**One refactor falls out of migration:** `RecordingsLibrary.init` currently
takes `settings: AppSettings`. Change to `baseURL: URL`. `AppCoordinator`
does the wiring. Keeps `RecordingStorage` from depending on `AppSettings`.

**Public API surface per module** (only what `AppCoordinator` or UI views
need):

- `AppSettings`: the `AppSettings` `@Observable` class, `OutputFormat` enum.
- `RecordingStorage`: `RecordingStore`, `RecordingFolder`,
  `RecordingsLibrary`, `RecordingMetadata`.
- `RecordingCore`: `RecordingSession`, `RecorderStateMachine` (once
  extracted), `MicRecorder.requestPermissionIfNeeded`,
  `AudioCapturePermission.requestIfNeeded`, `FLACExporter.export`,
  `OutputConversionPlanner`.

Everything else stays `internal`. No `@_exported import` re-exports.

## 4. Repo structure & `Package.swift`

**Target repo layout after migration:**

```
audio-pipeline/                       # repo root
├── audio-pipeline.xcodeproj/
├── audio-pipeline/                   # synchronized group (app target source)
│   ├── audio_pipelineApp.swift
│   ├── AppCoordinator.swift
│   ├── Assets.xcassets/
│   └── UI/
│       ├── MenuBarContent.swift
│       ├── RecordingsView.swift
│       └── SettingsView.swift
├── Packages/
│   └── AudioPipeline/                # umbrella SPM package
│       ├── Package.swift
│       ├── Sources/
│       │   ├── AppSettings/
│       │   ├── RecordingStorage/
│       │   └── RecordingCore/
│       └── Tests/
│           ├── AppSettingsTests/
│           ├── RecordingStorageTests/
│           └── RecordingCoreTests/
├── audio-pipelineTests/              # Xcode app-hosted test target (kept)
├── Info.plist
├── audio-pipeline.entitlements
├── docs/, scripts/, CLAUDE.md, …
```

**Synchronized-group constraint:** `audio-pipeline/` (the
`PBXFileSystemSynchronizedRootGroup` folder) and `Packages/AudioPipeline/Sources/`
must not overlap. Putting the package under a sibling `Packages/` directory
satisfies this. Migration physically moves files out of
`audio-pipeline/{Audio,Storage,Settings}/` into the appropriate package
source folder; the synchronized group automatically stops tracking them.
No `pbxproj` hand-editing.

**`Package.swift`:**

```swift
// swift-tools-version: 6.2
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let nonisolatedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS("26.3")],
    products: [
        .library(name: "AppSettings",      targets: ["AppSettings"]),
        .library(name: "RecordingStorage", targets: ["RecordingStorage"]),
        .library(name: "RecordingCore",    targets: ["RecordingCore"]),
    ],
    targets: [
        .target(name: "AppSettings",      swiftSettings: mainActorSettings),
        .target(name: "RecordingStorage", swiftSettings: mainActorSettings),
        .target(
            name: "RecordingCore",
            dependencies: ["RecordingStorage"],
            swiftSettings: nonisolatedSettings
        ),
        .testTarget(name: "AppSettingsTests",
                    dependencies: ["AppSettings"],
                    swiftSettings: mainActorSettings),
        .testTarget(name: "RecordingStorageTests",
                    dependencies: ["RecordingStorage"],
                    swiftSettings: mainActorSettings),
        .testTarget(name: "RecordingCoreTests",
                    dependencies: ["RecordingCore"],
                    swiftSettings: nonisolatedSettings),
    ]
)
```

`swift-tools-version: 6.2` is required for `.defaultIsolation` (SE-0466).
The two upcoming-feature flags mirror what the app target gets from
`SWIFT_APPROACHABLE_CONCURRENCY = YES`, so behavior matches across the
package/app boundary. Platforms set to `macOS("26.3")` to match the app
target's deployment floor. No external dependencies — matches the
project doc's no-deps rule.

## 5. App target ↔ packages wiring

**Adding the local package:** in Xcode, File → Add Package Dependencies →
Add Local → select `Packages/AudioPipeline/`. Then on the `audio-pipeline`
target → Frameworks, Libraries → add all three library products. This
populates `XCLocalSwiftPackageReference` and `XCSwiftPackageProductDependency`
entries in `project.pbxproj`. Commit the pbxproj change.

**What the app target imports:**

```swift
import AppSettings
import RecordingStorage
import RecordingCore
```

Each import pulls only what's used. No umbrella `import AudioPipeline`.

**What stays in the app target:**

- `audio_pipelineApp.swift` — `@main` `App` struct.
- `AppCoordinator.swift` — composition root. Imports all three libraries,
  wires instances together. After migration, calls
  `RecordingsLibrary(baseURL: settings.recordingsDirectory)` (the refactor
  flagged in §3).
- `UI/MenuBarContent.swift`, `UI/RecordingsView.swift`, `UI/SettingsView.swift`.
- `Assets.xcassets/`.
- `Info.plist`, `audio-pipeline.entitlements`. Entitlements are app-scoped;
  package code inherits them at runtime.

**No reverse dependency:** packages never import the app target. App
target depends on packages; never the other way around.

## 6. Testing strategy

**Default rule:** tests live inside each package, written in Swift Testing,
run via `swift test` from the package directory. This is the only path that
runs fully autonomously inside the safehouse — `swift test` doesn't codesign
or set up an app container, so the nested-sandbox codesign blocker doesn't
apply.

**App-hosted `audio-pipelineTests` Xcode target stays alive** for the small
integration slice that needs an app host: Core Audio process taps,
`AVAudioEngine` with real input devices, the TCC private SPI, the menu bar
in a running `NSApp`. Those run from Xcode or `xcodebuild test` (still
subject to the codesign-in-nested-sandbox blocker, accepted for that small
minority).

**Test distribution:**

| Test target | Tests | Runs |
|---|---|---|
| `AppSettingsTests` (SPM) | Preferences read/write, default-value behavior, `OutputFormat` enum semantics | `swift test`, autonomous |
| `RecordingStorageTests` (SPM) | Folder-naming rules, ISO-8601 stripping, metadata sidecar round-trip, `RecordingsLibrary` listing/refresh against tmp dir | `swift test`, autonomous |
| `RecordingCoreTests` (SPM) | `RecorderStateMachine` transitions, `OutputConversionPlanner` decisions, FLAC export against fixture CAF, `AudioFileWriter` framing | `swift test`, autonomous |
| `audio-pipelineTests` (Xcode, app-hosted) | Process-tap setup/teardown, mic permission flow, full record-to-stop integration smoke | Xcode or `xcodebuild test`, manual or CI |

**Reconciliation with the in-flight test-coverage work** (spec
`docs/superpowers/specs/2026-05-22-test-coverage-design.md`, plan
`docs/superpowers/plans/2026-05-22-test-coverage.md`): that plan was committed
two days ago against the freshly scaffolded `audio-pipelineTests` target. After this migration, deterministic tests in that plan land in the
SPM test targets instead. The integration carve-out (the same one §1 of the
test-coverage spec already isolates as needing real hardware) still lands in
`audio-pipelineTests`. Execution of the test-coverage plan pauses until this
migration is merged; then the plan is rewritten against the new test target
locations.

**Gotcha** (from research): SPM package test targets default to
`ENABLE_TESTABILITY = NO`. Only matters if a test needs `@testable import`
internals. Default is fine for testing public API; expose `package`-scoped
helpers or override `ENABLE_TESTABILITY` per test target if a specific test
needs it. Worth knowing; not worth designing around upfront.

**Xcode scheme behavior:** Xcode auto-creates a per-package test scheme. SPM
test targets won't appear in the app's `.xctestplan` unless explicitly
added — keep them separate. App scheme runs `audio-pipelineTests`
(integration); each package has its own scheme (or just `swift test`) for
unit tests.

## 7. Migration plan

Three increments, leaves first, each independently shippable. Each
increment ends with a green build and a commit.

1. **`AppSettings`.** Lowest-risk dress rehearsal. Create
   `Packages/AudioPipeline/` with initial `Package.swift` (one library
   product, one target, one test target). `git mv` `AppSettings.swift` into
   `Sources/AppSettings/`. Add the library product to the app target's link
   dependencies in Xcode. Fix the import in `AppCoordinator.swift`. Build.
   Commit.

2. **`RecordingStorage`.** Add the second library product and target to
   `Package.swift`. `git mv` `RecordingStore.swift`, `RecordingMetadata.swift`,
   `RecordingsLibrary.swift` into `Sources/RecordingStorage/`. Apply the
   `RecordingsLibrary.init(baseURL:)` refactor (drop the `AppSettings`
   parameter). Update `AppCoordinator.swift` call site to pass
   `settings.recordingsDirectory` directly. Add the library to the app
   target. Build. Commit.

3. **`RecordingCore`.** Add the third library product and target with
   `dependencies: ["RecordingStorage"]`. `git mv` `AudioCapturePermission.swift`,
   `AudioFileWriter.swift`, `FLACExporter.swift`, `MicRecorder.swift`,
   `ProcessTapRecorder.swift`, `RecordingSession.swift` into
   `Sources/RecordingCore/`. Add the library to the app target. Fix imports
   in `AppCoordinator.swift`. Build. Commit.

4. **Cleanup.** Delete the now-empty `audio-pipeline/Audio/`,
   `audio-pipeline/Storage/`, `audio-pipeline/Settings/` directories. Commit.

After each step the app builds and runs unchanged from a user's perspective.
Recorder behavior is identical; only the module a file lives in has changed.

**Order vs the in-flight test-coverage plan execution:** pause the
test-coverage plan until migration is merged. Don't interleave — tests being
written against files that are about to move risks rework. After migration:
rewrite the test-coverage plan against the new SPM test target locations,
then execute.

## 8. Future milestones (where new modules plug in)

| Milestone | Added to umbrella package | Notes |
|---|---|---|
| **M2 pipeline** | `PipelineKit` (`PipelineNode` protocol, registry, run context), `PipelineRuntime` (queue, executor, SQLite-backed run logs) | Two modules so connectors depend on `Kit` without dragging in the runtime |
| **M2/M3 connectors** | One module per connector: `ConnectorTranscribeGemini`, `ConnectorOutputObsidian`, etc. | Anti-pattern explicitly avoided: a single `Connectors` umbrella. App target imports just the ones it ships with. |
| **M4 dictation (in-app)** | `DictationKit` (engine protocol, hotkey, paste), `DictationRemoteEngine` | Engine is an abstraction; remote engine ships in the binary. |
| **M4 dictation (local)** | **Satellite project** outside `Packages/AudioPipeline/` | Own `.xcodeproj`, builds a `.bundle` codesigned with the same Team ID, downloaded by the main app at runtime, loaded via `Bundle(url:).load()`. MLX-Swift dependency lives only here. |

The umbrella package never gains an MLX dependency. The satellite has no
counterpart in this migration; only the `DictationKit` engine-protocol seam
(added in M4) creates the contract the satellite will eventually load
against.

## 9. Open questions / deferred unknowns

- **Satellite Gatekeeper handling.** Whether downloaded-then-loaded code in a
  sandboxed App Support container needs `xattr` quarantine removal or a
  Gatekeeper rescan is not settled by the 2025-2026 sources surveyed. Needs
  a 1-day spike before M4: build a trivial `.bundle`, sign with the same
  Team ID, write to the sandboxed app's container, attempt to load via
  `Bundle(url:).load()`, observe whether library validation blocks it.
  Deferred until M4 starts; flagged here so it isn't forgotten.
- **Interface+Live split.** Connector modules may eventually adopt the
  Point-Free pattern (interface module + live implementation module). Not
  worth it at 3-5 connectors. Can be retrofitted module-by-module if
  testability needs grow.
- **`PipelineRunner` as a separate top-level package.** If the pipeline
  runner is later moved into a launchd-managed background helper (project
  doc, §architecture sketch), it may warrant its own top-level package for
  independent build / sign. The umbrella → multi-package refactor is
  mechanical when needed.
- **UI as a `Features` module.** Currently in the app target. If UI surface
  grows substantially, it can move into a package module. No need now.

## 10. Out of scope

- Building any M2/M3/M4 code. Structural migration only.
- Resolving the codesign-in-nested-sandbox blocker for the app-hosted test
  target. The migration removes the pressure (most tests move to `swift
  test`) but does not solve the underlying issue for the integration carve-out.
- Splitting `RecordingCore` into smaller modules (e.g., separating system-tap
  from mic capture). Premature given the size; revisit if the module grows.
- Adding `@_exported import` re-exports for convenience. Explicit
  per-library imports stay the rule.
- CI configuration. `swift test` from the package directory is the autonomous
  path; CI wiring is a separate concern.
