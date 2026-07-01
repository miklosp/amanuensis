# On-device transcription as a first-class "Local" source — Design

> Status: approved design (2026-07-01). Follow-up to the merged on-device transcription
> feature (PR #20). Companion: `docs/local-transcription-backend-research.md`,
> `docs/superpowers/plans/2026-06-30-local-transcription.md`.

## Goal

Make on-device transcription a first-class **source** in the UX — selectable like a
provider, with the right models offered — while internally it is *not* a stored
provider or preset. Also fix on-device **dictation**, which was never wired.

Seven changes:
1. Fix on-device dictation (the real bug).
2. Represent "Local" as a `TranscriptionSource` (hybrid: enum in code, sentinel on disk).
3. Remove the `on-device` preset.
4. Show **Local** in the provider dropdown (Jobs + Dictation) whenever a model is downloaded.
5. Model selector: **Local = strict dropdown** of downloaded models; **Cloud = editable + suggestions**.
6. Move the Models page into the main window as a **"Local Models"** sidebar item under Providers.
7. **Model memory management**: keep the selected dictation model warm; show "Dictation" and
   "In memory" state on the Local Models page.

## Current state (what we're changing)

- A transcription target is a stored `Provider` (`id`, `name`, `presetID`, `apiKeyRef`,
  `baseURL`) referenced by `Job.providerID: UUID?` and `settings.dictation.providerID`.
  Both are **persisted as JSON** (`JobsStore` encodes `[Job]`; dictation settings in `AppSettings`).
- `Provider → Preset → JobShape` drives dispatch. Model is a **free-text** field with a
  "Suggested" menu (`JobEditorView`), sourced from `preset.suggestedModels`.
- On-device was shipped as a keyless `Provider` built from an `on-device` **preset**
  (shape `.localTranscription`). The user wants Local to stop being a provider/preset.
- **Batch** jobs dispatch through `AppCoordinator.runJob` → `JobRunner(keychain:handlers:)`
  with `LocalTranscriptionSender` merged in (Task 16). **Dictation** dispatches through a
  *separate* path — `DictationCoordinator` → `BatchTranscriber` — whose `handlers` default
  to `JobRunner.defaultHandlers` (no local handler) and which reads the keychain
  unconditionally. So on-device dictation throws `unsupportedShape`, and a keyless Local
  would also hit `KeychainStore.Error.itemNotFound`.

## Design decisions

### D1 — Hybrid `TranscriptionSource` (enum in code, sentinel on disk)

Persisted fields (`Job.providerID`, dictation `providerID`) stay `UUID?` — **no schema
migration**. A reserved sentinel `Provider.localID` (a fixed constant `UUID`) means Local.
A single boundary helper converts to a domain enum used by all logic:

```
public enum TranscriptionSource: Equatable, Sendable {
    case none            // providerID == nil
    case local           // providerID == Provider.localID
    case provider(UUID)  // a stored provider
}
```

- `TranscriptionSource(providerID:)` maps `nil → .none`, `.localID → .local`, else `.provider(id)`.
- The magic UUID is quarantined to this one function; every dispatch/UI site does an
  exhaustive `switch source`, getting compiler-enforced completeness.
- Shape resolution: `.local → .localTranscription`; `.provider(id) → preset(provider).shape`;
  `.none → nil`.
- Lives in `AudioPipelineJobs` (alongside `Job`/`Provider`/`JobShape`) so both the SPM
  dispatch layer and the app UI share it.

### D2 — Remove the `on-device` preset

- Delete the `on-device` row from `presets.json`; `PresetsStoreTests` count 16 → 15.
- `JobShape.localTranscription` and `requiresAPIKey`/`requiresModel` **stay** — the shape is
  still how dispatch routes; only the preset is gone.
- The keyless relaxation in `ProviderEditorView.canSave` becomes dead (no keyless preset
  exists) → revert it as cleanup.
- Orphan handling (explicit): on provider load, **drop** any stored provider whose
  `presetID` matches the removed `on-device` preset id. The on-device *provider* concept is
  going away entirely, so this cleanly removes the dangling entry rather than leaving a
  broken provider in the repair pane. A job/dictation setting that pointed at such a provider
  then resolves to `.none` (repair/unset) and the user re-picks **Local** — no silent
  mis-dispatch. (Chosen over the do-nothing/repair-pane path so nothing broken lingers.)

### D3 — Fix on-device dictation

- `BatchTranscriber`: gate the keychain read — `let key = shape.requiresAPIKey ? try await keychain.get(...) : ""`
  — and resolve its handler from a handler map that **includes** `LocalTranscriptionSender`.
- `DictationCoordinator` receives the local-inclusive handlers (or the local sender) from
  `AppCoordinator` (which owns `localService`). `resolveTranscriberInputs` maps a `.local`
  selection → a `Job` with shape `.localTranscription`, `model = settings.dictation.model`,
  empty fields, no real provider. Because `AudioJobSending.send(provider:)` is non-optional
  and `LocalTranscriptionSender` ignores the provider, dictation passes a **transient
  placeholder** `Provider` for the local case (not stored) — documented as such.

### D4 — Local in the provider dropdown

- Both the Jobs provider `Picker` and the Dictation provider `Picker` append a **"Local"**
  row (tag `Provider.localID`) **iff** `localModelsStore` has ≥1 downloaded model
  (`states[id].isDownloaded`). No downloaded model → no Local row.
- Selecting Local ⇒ source `.local`, shape `.localTranscription`, no key, no baseURL.

### D5 — Model selector (`local strict, cloud editable`)

Extract a small reusable `ModelSelector` view used by **both** `JobEditorView` and the
Dictation settings:
- **Local** → strict `Picker` over downloaded model ids, showing
  `LocalModelCatalog.model(id).displayName`; value is the model id. Can't select an
  un-downloaded model.
- **Cloud** → editable `TextField` + a suggestions dropdown / type-ahead from
  `preset.suggestedModels` (preserves custom cloud models). Improves today's
  free-text-plus-"Suggested"-menu.

### D6 — "Local Models" in the main window

- Add `SidebarDestination.localModels`; a sidebar `Label("Local Models", …)` immediately
  after **Providers** in `MainWindowView`; detail shows `ModelsView(store: coordinator.localModelsStore)`.
- Remove the Models entry from `SettingsView` (reverts the Settings `NavigationStack` wrap +
  `Section("Models")` added in the merged PR).

### D7 — Model memory management (warm dictation model)

The engines currently load the model fresh on every `transcribe` call — fine for batch,
fatal for dictation latency (multi-second cold load before the first utterance is live).
Introduce a single **resident (warm) model**:

- **Dictation:** the selected Local dictation model is kept resident **while it is selected**.
  Preloaded eagerly when the app starts (if that model is downloaded) and re-loaded whenever
  the dictation model changes (unload previous → load new). First utterance is then instant.
- **Batch:** keeps today's transient behavior. If a batch job's model equals the resident
  one, it reuses it (free win); otherwise it loads its own instance, transcribes, and
  releases it — **without evicting the resident dictation model**. Peak memory during such a
  job is `resident + transient`; a ~2 GB Cohere resident plus another transient is heavy, so
  the choice of dictation model is the user's memory budget. This matches the user's intent
  ("batch can load-unload; dictation stays loaded"). **No idle auto-unload in v1** — resident
  while selected.
- **At most one** resident model at a time (= the dictation model).

Engine / service shape:
- Extend `LocalTranscriptionEngine` with `preload(_ model) async throws` and
  `unloadResident() async`. Each engine actor caches its loaded handle (`AsrManager` /
  `WhisperKit` pipeline) keyed by model id and reuses it in `transcribe` when it matches
  (this also addresses the PR's "reloads every call" note for the warm path). The transient
  batch load stays a separate, released instance so it never evicts the pinned model.
- `LocalTranscriptionService` tracks the pinned dictation model, forwards `preload`/`unload`
  to the owning engine, and exposes an observable `residentModelID: String?`.
- `LocalModelsStore` reflects `residentModelID` (In memory) and the selected dictation model.

Local Models page (extends D6):
- Each row shows two badges: **"Dictation"** (selected as the Local dictation model) and
  **"In memory"** (currently resident), with a brief loading indicator while preloading.

## Data flow

```
Picker selection ──▶ providerID: UUID? (persisted; .localID = Local)
                         │
                 TranscriptionSource(providerID:)
                         ▼
         ┌─ .local     → shape .localTranscription; models = downloaded catalog; key ""
         ├─ .provider  → shape = preset.shape;      models = preset.suggestedModels; key = keychain.get
         └─ .none      → unset (draft/repair)
                         ▼
   Batch:  AppCoordinator.runJob → JobRunner(keychain, handlers⊇local) → sender
   Dict.:  DictationCoordinator → BatchTranscriber(handlers⊇local, keyless-gated) → sender
                         ▼
           LocalTranscriptionSender → LocalTranscriptionService → engine   (Local)
           existing cloud sender                                            (Provider)
```

Separately, a **preload lifecycle** keeps the dictation model warm: on app start and on any
dictation-model change, `AppCoordinator` calls `service.preload(dictationModelID)` (or
`unloadResident()` when dictation leaves Local), independent of any transcribe call.

## Error handling

- Local + keyless: no keychain access (gated on `requiresAPIKey`) — the `itemNotFound`
  path is not reached.
- Local model not downloaded: it can't be selected (strict dropdown), and Local doesn't
  appear at all with zero downloaded models. Defense in depth: `LocalTranscriptionSender`
  already throws `unsupportedModel` for an unknown id and the service surfaces
  `modelNotDownloaded`.
- Cloud path unchanged: keychain read + handler errors surface as today.

## Testing

Autonomous (Swift Testing, against fakes — no device/ANE/network):
- `TranscriptionSource(providerID:)` mapping (nil/localID/other) and shape resolution.
- `BatchTranscriber`: keyless shape skips the keychain and routes to the local handler
  (the `unsupportedShape` bug is gone); a keyful shape still calls `keychain.get` and its
  handler. Uses a spy keychain + spy sender (mirror `JobRunnerTests`).
- "Local appears iff ≥1 model downloaded" — the pure predicate over `LocalModelsStore` state.
- Model-selector data source: `.local → downloaded ids`; `.provider → suggestedModels`.
- `presets.json` no longer contains `on-device` (count 15).
- Resident-model lifecycle against a fake engine that records load/unload: `preload` pins;
  changing the dictation model unloads the old and loads the new; a batch transcribe with a
  *different* model does not evict the resident; a batch transcribe with the *same* model
  reuses it (no reload); `residentModelID` is reflected in the store.

Device-verified (manual, unchanged policy):
- Local Models page renders in the main window under Providers, with "Dictation" / "In
  memory" badges on the right rows.
- On-device **dictation** produces a transcript and pastes, and the *first* utterance after
  app start is fast (warm model — no multi-second cold load).
- The provider dropdown shows Local once a model is downloaded; the model dropdown lists
  the downloaded models; cloud model field still accepts a custom value.

## Files touched (indicative)

- **`Packages/AudioPipeline/Sources/AudioPipelineJobs/`** — new `TranscriptionSource` +
  `Provider.localID`; `presets.json` (remove row); tests.
- **`Packages/AudioPipeline/Sources/LocalTranscription/`** — `LocalTranscriptionEngine`
  gains `preload`/`unloadResident`; `FluidAudioEngine`/`WhisperKitEngine` cache the loaded
  handle keyed by model id; `LocalTranscriptionService` tracks + exposes `residentModelID`;
  `LocalModelsStore` reflects `residentModelID` + selected dictation model; tests.
- **`Amanuensis/Dictation/BatchTranscriber.swift`**, **`DictationCoordinator.swift`** —
  keyless gating + local handler + `.local` resolution.
- **`Amanuensis/AppCoordinator.swift`** — provide local-inclusive handlers to dictation;
  drop orphaned on-device providers on load; preload lifecycle (app start + dictation-model
  change → `service.preload` / `unloadResident`).
- **`Amanuensis/UI/MainWindowView.swift`** — `localModels` sidebar destination.
- **`Amanuensis/UI/SettingsView.swift`** — remove Models link (revert wrap); dictation
  provider/model uses the new `ModelSelector`.
- **`Amanuensis/UI/Jobs/JobEditorView.swift`** — provider Picker adds Local; model field
  → `ModelSelector`.
- **`Amanuensis/UI/Models/ModelRowView.swift`** — "Dictation" / "In memory" badges.
- **`Amanuensis/UI/Providers/ProviderEditorView.swift`** — revert dead keyless relaxation.
- **New** `Amanuensis/UI/.../ModelSelector.swift` — the reusable selector.

## Out of scope / deferred

- Live/streaming on-device dictation (a `DictationTranscriber` with partials) — still the
  deferred item in `docs/local-transcription-backend-research.md §11`. This spec only makes
  the existing **batch** dictation path work with the on-device engine.
- A future non-provider `.server(...)` source — the `TranscriptionSource` enum leaves room
  for it, but it is not built here.
- Idle auto-unload of the resident model, multi-model residency, or an LRU cache beyond the
  single pinned dictation model — v1 keeps exactly one resident model, pinned while selected.
