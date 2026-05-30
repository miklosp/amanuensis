# Providers / Jobs Split — Design

**Date:** 2026-05-30
**Status:** Approved (brainstorm)
**Scope:** `AudioPipelineJobs` SPM target + `audio-pipeline/UI/Jobs/` + `MainWindowView`.

## Goal

Split today's monolithic `Job` into two concepts:

- **Provider** — user-defined API endpoint + credentials, pinned to a wire-level shape.
- **Job** — references a Provider and customises a single audio→text run (model, prompt, params, output).

Today a `Job` carries `name`, `presetID`, `baseURL`, `model`, `apiKeyRef`, `fields`, `outputExt`, `outputFolderPath`. The first three fields are really "which API to call" — they get reused across many Jobs against the same vendor and rot inline because there's no shared object. After the split, those move to `Provider` and a Job just points at one.

## Non-goals

- No new transport shapes, handlers, or model integrations.
- No "test connection" affordance on the Provider editor.
- No migration code for existing `jobs.json` — pre-release, single user, wipe and reconfigure.
- No rename of the `AudioPipelineJobs` SPM target.

## Data model

```
Provider (NEW, persisted in providers.json)
├─ id: UUID
├─ name: String                  // user label, e.g. "OpenAI", "Self-hosted Whisper"
├─ presetID: String              // pins shape + supplies suggested models / baseURL default
├─ baseURL: String               // defaulted from preset, editable
└─ apiKeyRef: KeychainRef

Job (RESHAPED, persisted in jobs.json)
├─ id: UUID
├─ name: String                  // user label, e.g. "Swedish lesson"
├─ providerID: UUID?             // nil = unset (draft / broken state)
├─ model: String                 // per-job model choice
├─ fields: [String: String]      // shape-derived params (prompt, temperature, …)
├─ outputExt: String
└─ outputFolderPath: String?
```

Moves off `Job` onto `Provider`: `presetID`, `baseURL`, `apiKeyRef`.
Stays on `Job`: `name`, `model`, `fields`, output config.

Shape lives on Provider via its preset. A Job's `fields` are validated against `provider.preset.shape`.

### Changing a Job's Provider

- **Same shape** as previous provider: keep `fields` and `model` (user can edit either).
- **Different shape**: reset `fields` to new shape's defaults (`preset.defaults`), clear `model`. Different shapes have different semantics for the same key (`prompt` means instructions for `chatCompletionsAudio`, vocabulary biasing for `transcriptionMultipart`) — silent carry-over would mislead.

### Broken Jobs

A Job whose `providerID` is `nil` or doesn't resolve in `ProvidersStore` is **broken**:

- Jobs list row shows an `exclamationmark.triangle` badge before the name.
- `JobEditorView` replaces the form with `ContentUnavailableView("Provider missing", systemImage: "key.slash", …)` plus a Picker over current providers to reassign (applying the same-shape / different-shape rules above).
- `AppCoordinator.runJob(_:)` throws `JobRunError.providerMissing` before invoking the runner.

No silent fallback to a "default" provider. The user explicitly repairs.

## Storage

```
Application Support/<bundleID>/
├─ providers.json    (NEW)
└─ jobs.json         (reshaped — old schema is unreadable, no migration)
```

`ProvidersStore` mirrors `JobsStore`:

- `@MainActor @Observable`, JSON-on-disk.
- `init(fileURL:) throws`, `static func standard(bundleID:) throws -> ProvidersStore`.
- `upsert(_:)`, `delete(id:)`, internal `load()` / `save()`.
- `provider(id:) -> Provider?` lookup helper.
- Pre-release wipe: if `jobs.json` exists with the old schema, `JobsStore.init` throws on decode; `AppCoordinator` catches and starts empty (logs once). `providers.json` simply doesn't exist on first launch with the new schema, which `load()` already handles.

`Preset` and `PresetsStore` are unchanged. Bundled `presets.json` is unchanged. The preset library now feeds the **Provider** editor instead of the Job editor.

## Files

```
Packages/AudioPipeline/Sources/AudioPipelineJobs/
├─ Provider.swift            (NEW)
├─ ProvidersStore.swift      (NEW)
├─ Job.swift                 (EDIT — fields removed/added per §Data model)
├─ JobsStore.swift           (UNCHANGED behaviour; persists new Job)
├─ JobRunner.swift           (EDIT — accepts Provider)
├─ ChatCompletionsAudioHandler.swift  (EDIT — reads baseURL from Provider)
├─ FieldSpec.swift           (unchanged)
├─ Preset.swift              (unchanged)
├─ PresetsStore.swift        (unchanged)
├─ KeychainRef.swift         (unchanged)
└─ KeychainStore.swift       (unchanged)

audio-pipeline/UI/
├─ MainWindowView.swift      (EDIT — sidebar gains .providers)
├─ Jobs/
│  ├─ JobsView.swift         (EDIT — empty-providers state, broken-job badge)
│  ├─ JobEditorView.swift    (EDIT — shrinks to job-only fields; Provider picker)
│  ├─ JobFieldFormView.swift (unchanged)
│  └─ KeychainAccountPicker.swift (unchanged, reused by Provider editor)
└─ Providers/                (NEW directory)
   ├─ ProvidersView.swift    (NEW — mirrors JobsView layout)
   └─ ProviderEditorView.swift (NEW — extracted from today's JobEditorView API half)
```

The synchronised `audio-pipeline/` group auto-picks-up `Providers/` and its files (no `pbxproj` edits needed).

## UI

### Sidebar

`MainWindowView` adds a third entry under `Library`:

```
Library
  Recordings
  Jobs
  Providers   ← new
```

`SidebarDestination` gains `.providers`. The detail switch routes to `ProvidersView(providers:, presets:, keychain:)`.

### `ProvidersView`

Structural copy of `JobsView`:

- `HSplitView` with sorted list on the left, `ProviderEditorView` on the right.
- Sort: `localizedStandardCompare` on `name`. Auto-select first; if selection disappears, reselect first.
- Toolbar: `+ New Provider`, `– Delete` (Delete disabled when nothing selected). Deletion is unrestricted — referencing Jobs become broken and surface through the badge UI.

### `ProviderEditorView`

The API-config half of today's `JobEditorView`, extracted:

- `Name` — TextField
- `Preset` — Picker over `presets.all`; on change, refills `baseURL` from `preset.baseURL`
- `Base URL` — TextField (editable for self-hosted)
- `API key` — `KeychainAccountPicker` (reused as-is)

Save enabled when `name`, `presetID`, and `apiKeyRef.account` are all non-empty.

### `JobEditorView` (shrunk)

- `Name`
- `Provider` — Picker over `providers.all` (by name). On change: apply the same-shape / different-shape rules from §Data model.
- `Model` — TextField, with `Suggested` menu sourced from `provider.preset.suggestedModels`
- `Parameters` — `JobFieldFormView(shape: provider.preset.shape, values: $fields)` (unchanged renderer)
- `Output extension` — TextField
- `Custom output folder` — Toggle + path + `Choose…` (unchanged behaviour)

Save enabled when `name` is non-empty, `providerID` is non-nil, `model` is non-empty, and (if custom folder) the folder path is non-empty.

### Empty Providers state

When `providers.all.isEmpty`:

- `JobsView` toolbar's `+ New Job` button is disabled.
- Clicking it (or trying to act on an empty list) shows a transient toast: **"Add a provider first."** with a "Go to Providers" button that sets the sidebar selection to `.providers`.
- If the Jobs list is empty and providers are empty, `ContentUnavailableView("No providers configured", systemImage: "key", description: Text("Add a provider first."))` with the same action button.

### Broken-Job UI

See §Data model → Broken Jobs.

## Runner

`JobRunner.run(job:audioURL:)` becomes `JobRunner.run(job:provider:audioURL:) async throws -> URL`. The runner stays Sendable; the call site resolves the Provider first:

```swift
guard let provider = providers.provider(id: job.providerID ?? UUID()) else {
    throw JobRunError.providerMissing
}
try await runner.run(job: job, provider: provider, audioURL: url)
```

`ChatCompletionsAudioSending.send(job:audioURL:apiKey:)` becomes `send(job:provider:audioURL:apiKey:)`. `DefaultChatCompletionsAudioSender` reads `provider.baseURL` instead of `job.baseURL`. Wire-format logic unchanged.

`JobRunError.providerMissing` is a new case the AppCoordinator throws before calling the runner. Surfaces in the UI via the existing job-activity error path.

## AppCoordinator

Adds:

```swift
let providers: ProvidersStore
```

constructed in the same pattern as `jobs`:

```swift
providers = try ProvidersStore.standard(bundleID: bundleID)
```

Injected into `ProvidersView` and `JobsView`.

## Tests

### SPM tests (`AudioPipelineJobsTests/`)

New:

- `ProviderTests.swift` — Codable round-trip, `Provider.makeDraft(presets:)` precondition (empty preset library → empty `presetID`/`baseURL`).
- `ProvidersStoreTests.swift` — load/upsert/delete/persistence; mirrors `JobsStoreTests` patterns.

Edited:

- `JobTests.swift` — drop `presetID` / `baseURL` / `apiKeyRef` assertions; add `providerID` round-trip including `nil` case.
- `JobsStoreTests.swift` — fixture builders rewritten; behaviour unchanged.
- `JobMakeDraftTests.swift` — assert draft `providerID == nil`.
- `JobRunnerTests.swift` — every fixture pairs a Job with a Provider; signature change propagates. No new `providerMissing` test at the runner layer (lives at AppCoordinator).
- `ChatCompletionsAudioHandlerTests.swift` — fixture rewrite; assert request URL is built from `provider.baseURL`.

Unchanged: `PresetsStoreTests.swift`, `PresetTests.swift`, `JobShapeTests.swift`, `KeychainStoreTests.swift`, `SmokeTests.swift`.

### App-hosted XCTest (`audio-pipelineTests/`)

No changes. `MainWindowViewTests` and `RecordingFormattersTests` don't touch Jobs internals.

## Success criteria

- `Job` no longer references `presetID`, `baseURL`, or `apiKeyRef`.
- `Provider` is created/edited/deleted from a new top-level sidebar entry.
- `JobEditorView` body is at most: Name, Provider, Model, Parameters, Output extension, Custom output folder.
- Deleting a Provider leaves referencing Jobs visibly broken (badge + repair prompt), not silently mutated.
- Toggling a Job's Provider across shapes resets `fields` and `model`; within a shape, preserves them.
- `swift test --disable-sandbox --package-path Packages/AudioPipeline` is green.
- App-hosted XCTest (`xcode-build-helper.sh … test`) is green.
- Manual smoke: create one Provider, create one Job pointing at it, run it against a real recording, get an output file.

## Out of scope (deferred)

- Per-Job override of Provider's `baseURL` / `apiKey` (use case: same shape but ad-hoc endpoint). If it comes up, add an `overrides` struct to `Job`.
- Provider tags / categories / favorites.
- Importing/exporting Providers as JSON.
- A "Test connection" button in the Provider editor.
- Reassigning all Jobs from Provider A to Provider B in one click.
