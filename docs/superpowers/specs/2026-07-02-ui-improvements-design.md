# UI improvements — design

**Date:** 2026-07-02
**Branch:** `worktree-ui-improvements`
**Scope:** Four independent UI changes to Amanuensis. No behavioural changes to the audio/recording/transcription engines — this is presentation, navigation, and one additive metadata field.

## Goals

1. Move the **Dictation** configuration out of Settings and into the main app window as its own sidebar destination. Strip permission rows out of it.
2. Add a **Mac privileges** section at the very top of Settings that surfaces all four system permissions the app uses.
3. Redesign the **Local Models** screen as a card grid, and show each model's full supported-language list as 2-char (ISO 639-1) codes.
4. Add a non-destructive **Rename…** action to the recordings context menu.

## Non-goals

- No change to how permissions are actually requested at record/dictation time (`AppCoordinator.startRecording` still calls `MicrophonePermission`/`AudioCapturePermission`). The new UI only surfaces status and offers an explicit grant path.
- No folder-move rename. Rename is a display title stored in metadata; the on-disk folder name (the recording's identity) is untouched.
- No per-track transcription, no changes to Jobs/Providers.

---

## Component 1 — Dictation moves to the main window

### Current state
`SettingsView` (`Amanuensis/UI/SettingsView.swift`) is one grouped `Form`. `Section("Dictation")` (lines 62–134) holds: enable toggle, trigger-key picker, hold-threshold slider, provider picker, `ModelSelector`, insert-mode picker, overlay toggle, **and two permission rows** (Input Monitoring, Accessibility).

`MainWindowView` (`Amanuensis/UI/MainWindowView.swift`) is a `NavigationSplitView` whose sidebar has one `Section("Library")` with five destinations, driven by `enum SidebarDestination { recordings, jobs, providers, localModels, logs }`.

### Change
- Add `dictation` to `SidebarDestination`.
- Add a sidebar row for Dictation **above the `Library` section** (its own leading entry — it is the app's headline feature, not a library item). Icon: `"text.viewfinder"` / `"quote.bubble"` (final pick during implementation; must not collide with the recording `waveform` icon).
- New `DictationView(settings: AppSettings, coordinator: AppCoordinator)` in `Amanuensis/UI/Dictation/` or `Amanuensis/UI/` rendering the current Dictation controls **minus the two permission rows**:
  - Enable dictation toggle → `coordinator.dictation.settingsChanged()`
  - Trigger-key picker (+ the Fn caveat text) → `settingsChanged()`
  - Hold-threshold slider
  - Provider picker → `Task { await coordinator.syncDictationWarmModel() }`
  - `ModelSelector` (unchanged wiring) → `syncDictationWarmModel()`
  - Insert-mode picker
  - Show-overlay toggle
- Lay the view out as a grouped `Form` (consistent with Settings) inside the detail pane, with `.navigationTitle("Dictation")`.
- Delete `Section("Dictation")` from `SettingsView`, along with the now-unused helpers that only served it (`holdThresholdBinding` moves to `DictationView`; `dictationSuggestedModels` and `downloadedLocalIDs` move to `DictationView`).

### Notes
- `DictationView` needs the same imports `SettingsView` used for these controls (`AppSettings`, `DictationCore`, `LocalTranscription`, `AudioPipelineJobs`).
- The two permission rows do not disappear — they move to Component 2.

---

## Component 2 — "Mac privileges" section at the top of Settings

### Current state
Microphone and system-audio permissions have **no Settings UI**; they are only requested at record time. Input Monitoring and Accessibility have grant rows buried at the bottom of the Dictation section. Helpers already exist:

- `MicrophonePermission.currentStatus() -> AVAuthorizationStatus`, `requestIfNeeded() async -> Bool` (`Packages/AudioPipeline/Sources/RecordingCore/MicrophonePermission.swift`).
- `AudioCapturePermission.isAuthorized() -> Bool`, `requestIfNeeded() async -> Bool` (`.../AudioCapturePermission.swift`) — TCC `kTCCServiceAudioCapture` via private SPI.
- `HotkeyTapMonitor.hasInputMonitoringAccess()` / `requestInputMonitoringAccess()`.
- `TextInserter.hasPostEventAccess()` / `requestPostEventAccess()`.

### Change
Add a new **first** `Section("Mac privileges")` in `SettingsView`, above `Section("Recordings")`, with four rows in this order:

1. **Microphone** — status from `MicrophonePermission.currentStatus()`.
2. **System Audio** — status from `AudioCapturePermission.isAuthorized()`.
3. **Input Monitoring** — status from `HotkeyTapMonitor.hasInputMonitoringAccess()` (moved from Dictation).
4. **Accessibility · post events** — status from `TextInserter.hasPostEventAccess()` (moved from Dictation).

Row behaviour (generalise the existing `permissionRow` builder):
- **Authorized** → green `Label("Granted", systemImage: "checkmark.circle.fill")`.
- **Not determined** → "Grant…" button that triggers the request:
  - Mic/System Audio: `Task { _ = await …requestIfNeeded(); refreshPermissions() }`.
  - Input Monitoring / Accessibility: synchronous request call, then `refreshPermissions()`.
- **Denied / restricted** → "Open Settings…" button that deep-links to the relevant System Settings pane (a re-request won't re-prompt once denied):
  - Mic: `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`
  - System Audio: `…?Privacy_ScreenCapture` (the pane that hosts audio-capture consent) — verify the exact anchor during implementation; fall back to the top-level Privacy & Security pane if the anchor is wrong.
  - Input Monitoring: `…?Privacy_ListenEvent`
  - Accessibility: `…?Privacy_Accessibility`

State:
- `SettingsView` gains `@State` for the two new statuses (`micStatus`, `systemAudioAuthorized`) alongside the existing `inputMonitoringGranted` / `postEventGranted`.
- `refreshPermissions()` re-reads all four.
- Re-read on `.onAppear` of the form (so returning from System Settings reflects the new grant) in addition to after a grant press. Cheap; keeps status honest.

Microphone status is tri-state (`authorized` / `notDetermined` / `denied`+`restricted`); System Audio is effectively tri-state too but the SPI only cheaply distinguishes authorized vs not — treat non-authorized as "offer request; if the request returns false, it was already denied". Keep the denied→Open-Settings affordance for mic (which has a real tri-state) and for input-monitoring/accessibility; for system audio, the Grant button both requests and, on failure, is the moment to surface Open-Settings.

Keep this minimal: one `permissionRow` builder parameterised by (title, state, primary action, optional open-settings action).

---

## Component 3 — Local Models card grid + language codes

### Current state
`ModelsView` renders `List(LocalModelCatalog.all) { ModelRowView(...) }`. `LocalModel` (`Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift`) has a free-text `languages: String` (e.g. `"99 languages"`) used only for display at `ModelRowView` line 30. **There is no structured language list.**

### Change

**Data (`LocalModel.swift`):**
- Add `public let supportedLanguages: [String]` — lowercase ISO 639-1 codes.
- Keep `languages: String` as the human summary line (it carries nuance like "25 European languages", "incl. Japanese, Chinese, Korean").
- Populate for all six catalog entries:
  - `parakeet-tdt-ctc-110m` → `["en"]`
  - `parakeet-tdt-v3` → the 25 European languages from the NVIDIA Parakeet TDT v3 model card (bg, hr, cs, da, nl, en, et, fi, fr, de, el, hu, it, lv, lt, mt, pl, pt, ro, sk, sl, es, sv, ru, uk) — verify against the card during implementation; the count must be 25.
  - `cohere-transcribe` → the 14 from `CohereAsrConfig.Language` raw values: `["en","fr","de","es","it","pt","nl","pl","el","ar","ja","zh","vi","ko"]`.
  - `whisper-large-v3-turbo` → the canonical Whisper language set (99 codes). Source the list from the Whisper `LANGUAGES` table; count must be 99.
  - `parakeet-tdt-ja` → `["ja"]`
  - `sensevoice-small` → SenseVoice's supported set (at minimum `["zh","yue","en","ja","ko"]`; if FluidAudio's SenseVoice config exposes more, use that). The `languages` summary already reads "50+…"; only include codes we can substantiate rather than padding to 50.

**View:**
- Replace `ModelsView`'s `List` with `ScrollView { LazyVGrid(columns: adaptive(min: 260), spacing) { ForEach(LocalModelCatalog.all) { ModelCardView(...) } } }`. In the ~600pt detail pane this yields ~2 columns and reflows narrower.
- New `ModelCardView` (replaces `ModelRowView`; keep the same inputs and `onDownload`/`onDelete` closures):
  - Header: `displayName` + existing badges (Recommended / Dictation / In memory).
  - `summary`.
  - Footer line: `"<size> · <languages>"` with a trailing disclosure chevron when `supportedLanguages.count > 1`.
  - Expanding (per-card `@State private var isExpanded`) reveals a wrapped grid of small 2-char code chips (adaptive `LazyVGrid` of fixed-width capsule chips, or a simple flow layout). Single-language models (`en`, `ja`) show the one code inline and no chevron.
  - Trailing controls: Download / Delete / download-progress / loading-unloading indicator — identical logic to `ModelRowView`.
  - Card chrome: rounded rectangle background (`.background(.quaternary, in: RoundedRectangle…)` or a `GroupBox`), padding.
- `ModelRowView.swift` is deleted (or renamed to `ModelCardView.swift`).
- `ModelSelector` is unaffected (it only uses `displayName`).

---

## Component 4 — Rename recordings (non-destructive)

### Current state
`RecordingMetadata` (`Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift`) has no title field. `RecordingItem` (`RecordingsLibrary.swift`) sets both `id` and `name` to `meta.folderName`; it is read-only, derived in `init?(folderURL:)`. `RecordingsLibrary` exposes only `refresh()` and `delete(_:)`. `RecordingsView` uses a selection-based `.contextMenu(forSelectionType:)` with Play / Reveal / Run Job / Delete.

### Change

**Metadata (`RecordingMetadata.swift`):**
- Add `public var title: String?` (additive optional; existing meta.json without the key decodes fine — `JSONDecoder` tolerates missing optionals). Add to the memberwise `init` with default `nil`. Keep `schemaVersion = 1` (additive, backward compatible).

**Item (`RecordingsLibrary.swift`):**
- `RecordingItem.name = meta.title?.trimming… (non-empty) ?? meta.folderName`.
- **`id` stays `meta.folderName`** — identity, selection, and Job/folder-path references are unchanged.

**Library (`RecordingsLibrary.swift`):**
- Add `func rename(_ item: RecordingItem, to newTitle: String) async`:
  - Read `item.folderURL/meta.json`, decode `RecordingMetadata`.
  - Set `title = trimmed.isEmpty ? nil : trimmed` (blank clears back to the folder name).
  - `try? meta.write(to: metadataURL)` (atomic, already implemented).
  - `await refresh()`.
  - Runs the decode/encode off the main thread if it proves heavy; a single-file read/write is fine inline for now.

**View (`RecordingsView.swift`):**
- Add a **"Rename…"** button to the context menu, single-item (operates on `first`, like Play/Reveal).
- State: `@State private var pendingRename: RecordingItem?` and `@State private var renameText: String`.
- Present an `.alert("Rename recording", isPresented:)` containing a `TextField` bound to `renameText`, with Rename (default) + Cancel. On Rename: `Task { await library.rename(item, to: renameText) }`. Mirrors the existing delete-alert structure. (macOS supports `TextField` inside `.alert`.)
- Prefill `renameText` with the current `name` when the menu opens the alert.

---

## Testing

**SPM (autonomous, `swift test --disable-sandbox --package-path Packages/AudioPipeline`):**
- `RecordingStorageTests` — new tests:
  - Writing a `RecordingMetadata` with `title` set, re-decoding, and confirming `RecordingItem.name` returns the title.
  - Rename with a blank string clears the title so `name` falls back to `folderName`.
  - A legacy meta.json without a `title` key still decodes (backward compatibility).
- `LocalModelCatalogTests` (`Packages/AudioPipeline/Tests/LocalTranscriptionTests/`) — new tests:
  - Every catalog model has a non-empty `supportedLanguages`.
  - Every code matches `^[a-z]{2,3}$` (allow `yue` for SenseVoice) and is lowercase.
  - Count assertions for the known-fixed models: Cohere == 14, Whisper == 99, Parakeet v3 == 25, single-language models == 1.

**App build (must pass after SPM):**
- `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` (SwiftUI views are not unit-tested; the rebuild is the compile check per CLAUDE.md).

**Manual smoke (documented, run by the user in-app):**
- Settings shows Mac privileges at top with four rows; grant/open-settings behave.
- Dictation appears in the main-window sidebar; controls work; no permission rows there.
- Local Models shows cards; language chips expand; download/delete unaffected.
- Right-click a recording → Rename… → new name persists across relaunch; folder name on disk unchanged.

## Implementation sequencing (subagents)

- **Components 3 and 4 are fully independent** (different files entirely) → parallel subagents.
- **Components 1 and 2 both edit `SettingsView.swift`** → one agent, done together/sequentially.
- Each agent writes its own tests and leaves the SPM suite green; a final integration pass rebuilds the app target and runs the full SPM suite before finishing the branch.

## Files touched (summary)

| Area | Files |
|------|-------|
| 1 Dictation move | `MainWindowView.swift`, new `DictationView.swift`, `SettingsView.swift` |
| 2 Mac privileges | `SettingsView.swift` |
| 3 Model cards | `LocalModel.swift`, `ModelsView.swift`, `ModelRowView.swift`→`ModelCardView.swift`, `LocalModelCatalogTests.swift` |
| 4 Rename | `RecordingMetadata.swift`, `RecordingsLibrary.swift`, `RecordingsView.swift`, `RecordingStorageTests.swift` |
