# On-device "Local" transcription source + dictation fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make on-device transcription a first-class "Local" source in the UX (selectable like a provider, with the right models offered and the dictation model kept warm), while internally it is not a stored provider or preset — and fix on-device dictation, which was never wired.

**Architecture:** A `TranscriptionSource` enum (hybrid: persisted as `providerID: UUID?` with a reserved `Provider.localID` sentinel — no schema migration — converted to the enum at the read boundary). The dictation path (`BatchTranscriber`) gets the local handler + keyless-key gating. `LocalTranscriptionService` gains a single resident (warm) model = the selected dictation model; engines cache the loaded handle. The Models page moves to the main window with "Dictation"/"In memory" badges. Model selectors become local-strict / cloud-editable.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing; existing `AudioPipelineJobs`, `LocalTranscription`, `DictationCore` SPM modules; WhisperKit 1.0.0 / FluidAudio 0.15.4.

## Global Constraints

- **Design spec:** `docs/superpowers/specs/2026-07-01-on-device-transcription-source-ux.md` is authoritative.
- **No persistence migration:** `Job.providerID` and `settings.dictation.providerID` stay `UUID?`. `Provider.localID` sentinel means Local.
- **`TranscriptionSource`:** `case none` (nil) | `case local` (`Provider.localID`) | `case provider(UUID)`. Local ⇒ shape `.localTranscription`, no key, no baseURL.
- **Module isolation:** domain (`TranscriptionSource`, resident-model service logic) is TDD'd in the SPM package (`swift test --disable-sandbox --package-path Packages/AudioPipeline`). App-target UI, real engine caching, and actual on-device dictation are **device-verified** (daemon app build `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` → JSON `"exit": 0`; then run the app). After SPM tests pass, always rebuild the app target.
- **Default actor isolation is `MainActor`** in the app target; the `LocalTranscription` module uses `nonisolatedSettings` (engines/service are actors; store is `@MainActor @Observable`).
- **Memory:** exactly ONE resident model (= the Local dictation model), pinned while selected; preloaded on app start + on dictation-model change; batch stays transient and must never evict the resident. No idle auto-unload in v1.
- **Model selector:** Local = strict dropdown of downloaded models; Cloud = editable field + suggestions from `preset.suggestedModels`.

---

## File Structure

**New (SPM `AudioPipelineJobs`):** `Sources/AudioPipelineJobs/TranscriptionSource.swift` (enum + `Provider.localID`).
**Modified (SPM):** `LocalTranscription/LocalTranscriptionEngine.swift` (+`preload`/`unloadResident`), `FluidAudioEngine.swift` + `WhisperKitEngine.swift` (cache loaded handle), `LocalTranscriptionService.swift` (resident tracking + `residentModelID`), `LocalModelsStore.swift` (`residentModelID` + `dictationModelID`), `AudioPipelineJobs/Resources/presets.json` (remove `on-device`), tests.
**New (app):** `Amanuensis/UI/Models/ModelSelector.swift`.
**Modified (app):** `Amanuensis/Dictation/BatchTranscriber.swift`, `DictationCoordinator.swift`, `AppCoordinator.swift`, `UI/MainWindowView.swift`, `UI/SettingsView.swift`, `UI/Jobs/JobEditorView.swift`, `UI/Models/ModelRowView.swift`, `UI/Providers/ProviderEditorView.swift`.

---

## Phase A — Domain (SPM, TDD)

### Task 1: `TranscriptionSource` + `Provider.localID`

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/TranscriptionSource.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/TranscriptionSourceTests.swift`

**Interfaces:**
- Produces: `extension Provider { public static let localID: UUID }`; `enum TranscriptionSource: Equatable, Sendable { case none, local, provider(UUID) }` with `init(providerID: UUID?)` and `var providerID: UUID?`.

- [ ] **Step 1: Write the failing test**

```swift
// TranscriptionSourceTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Test func nilProviderIsNone() {
    #expect(TranscriptionSource(providerID: nil) == .none)
}
@Test func localSentinelIsLocal() {
    #expect(TranscriptionSource(providerID: Provider.localID) == .local)
}
@Test func otherUUIDIsProvider() {
    let id = UUID()
    #expect(TranscriptionSource(providerID: id) == .provider(id))
}
@Test func providerIDRoundTrips() {
    #expect(TranscriptionSource.none.providerID == nil)
    #expect(TranscriptionSource.local.providerID == Provider.localID)
    let id = UUID()
    #expect(TranscriptionSource.provider(id).providerID == id)
}
@Test func localSentinelIsStable() {
    // A fixed, reserved constant — must never change (persisted on disk).
    #expect(Provider.localID.uuidString == "10CA110C-0000-0000-0000-000000000000")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TranscriptionSourceTests`
Expected: FAIL — `TranscriptionSource` / `Provider.localID` undefined.

- [ ] **Step 3: Implement**

```swift
// TranscriptionSource.swift
import Foundation

extension Provider {
    /// Reserved sentinel `providerID` meaning "on-device (Local)". Not a stored
    /// provider; recognised at the read boundary by `TranscriptionSource`. Fixed
    /// forever — it is persisted in saved jobs / dictation settings.
    public static let localID = UUID(uuidString: "10CA110C-0000-0000-0000-000000000000")!
}

/// The target of a transcription, resolved from the persisted `providerID: UUID?`.
/// Keeps the magic sentinel in ONE place so all logic switches exhaustively.
public enum TranscriptionSource: Equatable, Sendable {
    case none                 // providerID == nil (draft / unset)
    case local                // providerID == Provider.localID
    case provider(UUID)       // a stored provider

    public init(providerID: UUID?) {
        guard let id = providerID else { self = .none; return }
        self = (id == Provider.localID) ? .local : .provider(id)
    }

    public var providerID: UUID? {
        switch self {
        case .none: return nil
        case .local: return Provider.localID
        case .provider(let id): return id
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter TranscriptionSourceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/TranscriptionSource.swift Packages/AudioPipeline/Tests/AudioPipelineJobsTests/TranscriptionSourceTests.swift
git commit -m "feat(jobs): TranscriptionSource enum + Provider.localID sentinel"
```

### Task 2: Resident-model support in the engine protocol + service (TDD, fakes)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift`
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift`
- Modify: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FakeEngine.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/ResidentModelTests.swift`

**Interfaces:**
- Consumes: `LocalTranscriptionEngine`, `LocalModelCatalog`.
- Produces: protocol gains `func preload(_ model: LocalModel) async throws` and `func unloadResident() async`; `LocalTranscriptionService` gains `func preload(modelID: String) async throws`, `func unloadResident() async`, `func residentModelID() -> String?`.

- [ ] **Step 1: Extend `FakeEngine` to record load/unload** (test target)

Add to `FakeEngine` (an `actor`): `var residentID: String?`, `var transientTranscribes = 0`, `var reuseTranscribes = 0`.
```swift
func preload(_ model: LocalModel) async throws { residentID = model.id }
func unloadResident() async { residentID = nil }
```
And in the existing `transcribe`, before returning, record reuse vs transient:
```swift
if residentID == model.id { reuseTranscribes += 1 } else { transientTranscribes += 1 }
```
(Keep the existing `guard downloaded.contains(...)` behaviour.)

- [ ] **Step 2: Write the failing test**

```swift
// ResidentModelTests.swift
import Foundation
import Testing
@testable import LocalTranscription

private func svc() -> (LocalTranscriptionService, FakeEngine, FakeEngine) {
    let fa = FakeEngine(); let wk = FakeEngine()
    return (LocalTranscriptionService(fluidAudio: fa, whisperKit: wk), fa, wk)
}

@Test func preloadPinsResident() async throws {
    let (s, fa, _) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    #expect(await s.residentModelID() == "parakeet-tdt-ctc-110m")
    #expect(await fa.residentID == "parakeet-tdt-ctc-110m")
}

@Test func changingResidentUnloadsOld() async throws {
    let (s, fa, wk) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")   // FluidAudio
    try await s.preload(modelID: "whisper-large-v3-turbo")  // WhisperKit
    #expect(await s.residentModelID() == "whisper-large-v3-turbo")
    #expect(await fa.residentID == nil)                     // old engine unloaded
    #expect(await wk.residentID == "whisper-large-v3-turbo")
}

@Test func batchWithDifferentModelDoesNotEvictResident() async throws {
    let (s, fa, _) = svc()
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!) { _ in }
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-v3")!) { _ in }
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    _ = try await s.transcribe(audioURL: URL(fileURLWithPath: "/x"), modelID: "parakeet-tdt-v3", language: nil)
    #expect(await s.residentModelID() == "parakeet-tdt-ctc-110m")   // still pinned
    #expect(await fa.transientTranscribes == 1)
}

@Test func unloadResidentClears() async throws {
    let (s, fa, _) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    await s.unloadResident()
    #expect(await s.residentModelID() == nil)
    #expect(await fa.residentID == nil)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ResidentModelTests`
Expected: FAIL — `preload`/`unloadResident`/`residentModelID` undefined.

- [ ] **Step 4: Implement the protocol + service**

In `LocalTranscriptionEngine.swift`, add to the protocol:
```swift
    func preload(_ model: LocalModel) async throws
    func unloadResident() async
```
In `LocalTranscriptionService.swift`, add (inside the actor):
```swift
    private var residentID: String?

    public func residentModelID() -> String? { residentID }

    public func preload(modelID: String) async throws {
        if residentID == modelID { return }
        if let old = residentID, let (_, e) = try? resolve(old) { await e.unloadResident() }
        let (m, e) = try resolve(modelID)
        try await e.preload(m)
        residentID = modelID
    }

    public func unloadResident() async {
        if let old = residentID, let (_, e) = try? resolve(old) { await e.unloadResident() }
        residentID = nil
    }
```
(`resolve(_:)` is the existing private helper mapping modelID → `(LocalModel, engine)`.)

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ResidentModelTests`
Expected: PASS. Then run the full `LocalTranscriptionTests` filter to confirm the `FakeEngine` change didn't break Tasks 5/15's suites.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/FakeEngine.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/ResidentModelTests.swift
git commit -m "feat(local): service resident-model tracking (preload/unloadResident)"
```

### Task 3: `LocalModelsStore` — resident + dictation-selected state (TDD)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModelsStore.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelsStoreResidentTests.swift`

**Interfaces:**
- Produces: `LocalModelsStore` gains `var dictationModelID: String?` (set by the app), `private(set) var residentModelID: String?`, `func preload(modelID: String?) async` (preloads or unloads via the service and updates `residentModelID`), and `refresh()` also updates `residentModelID` from the service.

- [ ] **Step 1: Write the failing test**

```swift
// LocalModelsStoreResidentTests.swift
import Foundation
import Testing
@testable import LocalTranscription

@MainActor @Test func preloadUpdatesResidentModelID() async {
    let store = LocalModelsStore(service: LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine()))
    await store.preload(modelID: "parakeet-tdt-ctc-110m")
    #expect(store.residentModelID == "parakeet-tdt-ctc-110m")
    await store.preload(modelID: nil)   // unload
    #expect(store.residentModelID == nil)
}
```

- [ ] **Step 2: Run to verify it fails** — `--filter LocalModelsStoreResidentTests` → FAIL.

- [ ] **Step 3: Implement** — add to `LocalModelsStore`:
```swift
    public var dictationModelID: String?
    public private(set) var residentModelID: String?

    public func preload(modelID: String?) async {
        do {
            if let id = modelID { try await service.preload(modelID: id) }
            else { await service.unloadResident() }
            residentModelID = await service.residentModelID()
        } catch { lastError = error.localizedDescription }
    }
```
And in `refresh()`, after the existing loop, add: `residentModelID = await service.residentModelID()`.

- [ ] **Step 4: Run to verify it passes** — PASS. Run the full `LocalTranscriptionTests` filter too.

- [ ] **Step 5: Commit** `feat(local): store exposes residentModelID + dictationModelID`.

### Task 4: Retire the `on-device` preset

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift`
- Modify: `Amanuensis/AppCoordinator.swift` (drop orphaned providers on load)
- Modify: `Amanuensis/UI/Providers/ProviderEditorView.swift` (revert dead keyless relaxation)

- [ ] **Step 1: Remove the preset row** — delete the `{ "id": "on-device", … }` object from `presets.json`.

- [ ] **Step 2: Update the count test** — in `PresetsStoreTests.swift`, change the bundled-preset count assertion back to **15** and remove the `ids.contains("on-device")` assertion.

- [ ] **Step 3: Run SPM tests** — `swift test --disable-sandbox --package-path Packages/AudioPipeline` → all green (esp. `PresetCodable`/`PresetsStore`).

- [ ] **Step 4: Drop orphaned on-device providers on load** — in `AppCoordinator.loadProviders` (or right after it), filter out any stored provider whose `presetID == "on-device"` (its preset no longer exists), so no dangling broken provider remains. Read the current `loadProviders` and add the filter following its style.

- [ ] **Step 5: Revert the dead keyless relaxation** — in `ProviderEditorView.canSave`, revert to the pre-PR behaviour (no keyless branch — every preset now requires a key/URL). Read the current `canSave` and restore the original guard.

- [ ] **Step 6: App build** — `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` → `"exit": 0`.

- [ ] **Step 7: Commit** `feat(local): retire on-device preset; drop orphaned providers`.

---

## Phase B — Real engine caching (compile-verified; device-verified for warmth)

### Task 5: `FluidAudioEngine` + `WhisperKitEngine` — cache the loaded handle

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift`
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/WhisperKitEngine.swift`

**Interfaces:**
- Produces: each engine implements `preload(_:)`/`unloadResident()`; `transcribe` reuses the cached loaded handle when the requested model equals the resident one, otherwise loads a transient instance and releases it (never mutating the resident slot).

- [ ] **Step 1: FluidAudioEngine** — verify FluidAudio 0.15.4 signatures in `Packages/AudioPipeline/.build/checkouts/FluidAudio/`. Add stored state: `residentModelID: String?` + the loaded `AsrManager` (and, for SenseVoice/Cohere, the loaded pipeline/models) it belongs to. `preload(model)`: load the manager/models for `model` and store it as resident. `unloadResident()`: drop the stored handle + id. In `transcribe`: if `model.id == residentModelID`, reuse the stored handle; else keep today's load-transiently-then-return path (do NOT store it as resident). Keep each runner (parakeet/senseVoice/cohere) correct; only the parakeet/senseVoice/cohere manager that is actually resident is cached.

- [ ] **Step 2: WhisperKitEngine** — same: `residentModelID` + a stored `WhisperKit` pipeline. `preload`: build the pipeline (`WhisperKit(WhisperKitConfig(modelFolder:download:false))`) and store it. `unloadResident`: drop it. `transcribe`: reuse if resident matches, else build a transient pipeline and discard it after.

- [ ] **Step 3: Build** — `swift build --disable-sandbox --package-path Packages/AudioPipeline` → compiles. Do NOT run `xcodebuild`.

- [ ] **Step 4: Commit** `feat(local): engines cache the resident model handle (warm reuse)`.

*(Device verification of real warmth happens in Task 9.)*

---

## Phase C — Dictation wiring + preload lifecycle (app; device-verified)

### Task 6: `BatchTranscriber` + `DictationCoordinator` — wire on-device dictation

**Files:**
- Modify: `Amanuensis/Dictation/BatchTranscriber.swift`
- Modify: `Amanuensis/Dictation/DictationCoordinator.swift`
- Modify: `Amanuensis/AppCoordinator.swift`

- [ ] **Step 1: Gate the keychain + accept the local handler in `BatchTranscriber`** — change the unconditional key read to `let key = shape.requiresAPIKey ? try await keychain.get(account: provider.apiKeyRef.account) : ""`. Ensure its `handlers` map includes `.localTranscription: LocalTranscriptionSender(service:)` — accept the handlers via `init` (default `JobRunner.defaultHandlers`) so the coordinator injects the local-inclusive map. Keep `guard let handler = handlers[shape] else { throw DictationError.unsupportedShape }`.

- [ ] **Step 2: Resolve `.local` in `DictationCoordinator.resolveTranscriberInputs`** — compute `TranscriptionSource(providerID: settings.dictation.providerID)`. For `.local`: build the `Job` with `providerID: Provider.localID`, `model: settings.dictation.model`, `fields: [:]`, shape `.localTranscription`, and pass a **transient placeholder** `Provider` (e.g. `Provider(name: "Local", presetID: "", baseURL: "", apiKeyRef: KeychainRef(account: ""), id: Provider.localID)`) — the local sender ignores it. For `.provider`: keep today's provider/preset resolution. For `.none`: return nil (abort as today). Construct `BatchTranscriber` with the local-inclusive handlers.

- [ ] **Step 3: Provide the local handler + preload lifecycle from `AppCoordinator`** — expose the local-inclusive handlers (`JobRunner.defaultHandlers.merging([.localTranscription: LocalTranscriptionSender(service: localService)]) { _, n in n }`) to `DictationCoordinator`. Add preload lifecycle: after `settings.dictation` changes (the existing `dictation.settingsChanged()` path) and at app start, compute the source; if `.local` and the model is downloaded, `await localModelsStore.preload(modelID: settings.dictation.model)` and set `localModelsStore.dictationModelID`; otherwise `await localModelsStore.preload(modelID: nil)` and clear `dictationModelID`.

- [ ] **Step 4: App build** — daemon build → `"exit": 0`.

- [ ] **Step 5: Device verification** — set Dictation → provider **Local**, model = a downloaded model; confirm dictation produces text and pastes (no `unsupportedShape`, no keychain error), and the first utterance after app start is fast. Confirm a cloud dictation provider still works (reads its key).

- [ ] **Step 6: Commit** `feat(local): wire on-device dictation + warm-model preload lifecycle`.

---

## Phase D — UI

### Task 7: `ModelSelector` reusable view (local strict / cloud editable)

**Files:**
- Create: `Amanuensis/UI/Models/ModelSelector.swift`

- [ ] **Step 1: Implement** — a view taking the current `TranscriptionSource` (or an `isLocal` flag + a model list), a `@Binding var model: String`, the downloaded local model ids (with display names from `LocalModelCatalog`), and the cloud `suggestedModels`. Local → a strict `Picker` over downloaded model ids showing `LocalModelCatalog.model(id)?.displayName ?? id`. Cloud → an editable `TextField` + a suggestions menu/type-ahead from `suggestedModels` (mirror the existing `JobEditorView` TextField+Menu, improved). Keep it self-contained so both Jobs and Dictation reuse it.

- [ ] **Step 2: App build** → `"exit": 0`.

- [ ] **Step 3: Commit** `feat(local): reusable ModelSelector (local strict, cloud editable)`.

### Task 8: `JobEditorView` — Local in the provider picker + `ModelSelector`

**Files:**
- Modify: `Amanuensis/UI/Jobs/JobEditorView.swift`

- [ ] **Step 1:** In both provider `Picker`s, append a **"Local"** row (`Text("Local").tag(Optional(Provider.localID))`) **iff** the models store has ≥1 downloaded model. Pass the store into `JobEditorView` (via the existing `coordinator`/init wiring — read how `JobsView` constructs it). On selection change, when the new source is `.local`, set shape `.localTranscription` and reset model/fields appropriately (mirror the existing `autoFilledModel`/reset logic but for local: clear model, no fields).

- [ ] **Step 2:** Replace the Model `TextField`+`Menu` block with `ModelSelector`, driven by `TranscriptionSource(providerID:)`: local → downloaded ids; provider → `preset.suggestedModels`.

- [ ] **Step 3:** Update `canSave` / `preset`/`provider` derivation to treat `.local` as valid (shape `.localTranscription`, `requiresModel == true`, no key) — `provider` will be nil for local, so guard on source, not `provider != nil`.

- [ ] **Step 4:** App build → `"exit": 0`.

- [ ] **Step 5: Device verification** — create/edit a Job, pick **Local**, confirm the model dropdown lists downloaded models and the job runs on-device (`.txt` written). Confirm a cloud job still lets you type a custom model.

- [ ] **Step 6: Commit** `feat(local): Local source + ModelSelector in the Job editor`.

### Task 9: `SettingsView` dictation — Local picker + `ModelSelector`; remove Models link

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift`

- [ ] **Step 1:** In the Dictation section, add the **"Local"** row to the Provider `Picker` (tag `Provider.localID`) iff a model is downloaded. Replace the `TextField("Model", …)` with `ModelSelector` driven by `TranscriptionSource(providerID: settings.dictation.providerID)`. On provider/model change, trigger the coordinator's preload lifecycle (Task 6 Step 3).

- [ ] **Step 2:** Remove the `Section("Models")` + its `NavigationLink { ModelsView(...) }` (added in the merged PR); if the surrounding `NavigationStack` wrap was only for that link, revert it too.

- [ ] **Step 3:** App build → `"exit": 0`.

- [ ] **Step 4: Device verification** — Dictation now offers **Local** + a model dropdown; the warm model is preloaded (check the Local Models "In memory" badge once Task 10 lands); the Settings Models section is gone.

- [ ] **Step 5: Commit** `feat(local): Local dictation source + ModelSelector; drop Settings Models link`.

### Task 10: `MainWindowView` "Local Models" + `ModelRowView` badges

**Files:**
- Modify: `Amanuensis/UI/MainWindowView.swift`
- Modify: `Amanuensis/UI/Models/ModelRowView.swift`

- [ ] **Step 1:** Add `case localModels` to `SidebarDestination`; add a `Label("Local Models", systemImage: "cpu")` (or similar) immediately after the Providers row in the sidebar `List`; in the `detail` switch add `case .localModels: ModelsView(store: coordinator.localModelsStore).navigationTitle("Local Models")`.

- [ ] **Step 2:** In `ModelRowView`, add two badges when applicable: **"Dictation"** when `model.id == store.dictationModelID`, and **"In memory"** when `model.id == store.residentModelID` (pass these in, or the store, following the existing `ModelsView`→`ModelRowView` prop pattern). A small `ProgressView`/spinner may show while a preload is in flight (optional; only if easy).

- [ ] **Step 3:** App build → `"exit": 0`.

- [ ] **Step 4: Device verification** — "Local Models" appears in the sidebar under Providers; the row for the current dictation model shows **Dictation** + **In memory** once preloaded; deleting/redownloading still works.

- [ ] **Step 5: Commit** `feat(local): Local Models in main window + Dictation/In-memory badges`.

---

## Phase E — Final

### Task 11: Full-suite + app build + end-to-end sweep

- [ ] **Step 1:** `swift test --disable-sandbox --package-path Packages/AudioPipeline` → all green.
- [ ] **Step 2:** Daemon app build → `"exit": 0`.
- [ ] **Step 3: Device sweep** — (a) Local shows in Jobs + Dictation pickers only when a model is downloaded; (b) on-device dictation works and is warm; (c) batch on-device job writes `.txt`; (d) cloud provider/model still works (key + custom model); (e) Local Models page shows Dictation/In-memory badges; (f) removing the last downloaded model removes Local from the pickers.
- [ ] **Step 4: Commit** any final fixes; push the branch to update PR #20 (or open a follow-up PR) per the user's choice.

---

## Self-Review

- **Spec coverage:** D1 TranscriptionSource (Task 1) ✓; D2 remove preset + orphan drop + canSave revert (Task 4) ✓; D3 dictation wiring (Task 6) ✓; D4 Local in dropdown (Tasks 8/9) ✓; D5 ModelSelector (Tasks 7/8/9) ✓; D6 Local Models in main window (Task 10) ✓; D7 memory management — service (Task 2), store (Task 3), engines (Task 5), lifecycle (Task 6), badges (Task 10) ✓.
- **Placeholder scan:** full code for the TDD domain tasks (1–4 SPM). Device-verified tasks (5–10) give precise instructions + exact interfaces + the real signatures to adapt against (engines, SwiftUI), matching the proven approach of the prior plan's Phase D/E.
- **Type consistency:** `TranscriptionSource(providerID:)`, `Provider.localID`, `preload(_:)`/`unloadResident()`/`residentModelID()`, `LocalModelsStore.{residentModelID,dictationModelID,preload(modelID:)}`, `shape.requiresAPIKey`, `LocalTranscriptionSender(service:)` used consistently across tasks.
- **Known verification gap:** real engine warmth, on-device dictation, and all UI render only on device (not the SPM suite) — explicit device-verification steps in Tasks 6/8/9/10/11; fakes cover the source enum, resident-tracking, and store logic autonomously.
