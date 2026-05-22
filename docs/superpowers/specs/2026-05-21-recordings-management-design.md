# Recordings management — design

**Date:** 2026-05-21
**Status:** Approved (brainstorming)
**Scope:** M1

## Goal

Three related changes to how recordings are stored, surfaced, and exported:

1. **Move recordings to a visible, user-owned location** — default `~/Music/audio-pipeline/`, configurable in Settings.
2. **Add a Recordings window** — a browsable list of every recording.
3. **Add an output-format setting** — keep the lossless CAF master, a converted FLAC copy, or both.

## Current state

- The app is a classic menu-bar dropdown (`MenuBarExtra`, `.menu` style). No Settings scene, no windows.
- `RecordingStore` hardcodes `~/Library/Application Support/audio-pipeline/recordings/`.
- Each recording is a folder of `mic.caf`, `system.caf`, `meta.json` (see `RecordingMetadata`).
- `AppCoordinator` owns the recording lifecycle; `RecordingSession` owns one recording.

## Decisions

- **Location:** `~/Music/audio-pipeline/` by default (matches Audio Hijack; `~/Music` is not TCC-protected, so no permission prompt). User-configurable. App-internal state (M2's `queue.db`, pipeline definitions) stays in Application Support.
- **No migration.** Pre-release; existing test recordings in Application Support are disposable. The location setting is forward-looking — new recordings use the configured folder; existing recordings are not auto-moved.
- **Output format:** a 3-way radio — `caf` (master only, current behaviour, the default), `flac` (converted only), `both`.
- **FLAC shape:** per-track, 16 kHz mono — `mic.flac` and `system.flac`. The mic/system split is preserved for speaker attribution; the system track's L/R is down-mixed to mono.
- **FLAC encoding:** Core Audio's native `kAudioFormatFLAC` via `AVAudioFile` + `AVAudioConverter`. No third-party dependency (M1 rule holds).
- **Conversion timing:** asynchronous, after stop. The recording is complete the moment the CAFs are finalized; the FLAC appears in the list when ready. In `flac` mode the CAF is deleted only after its FLAC is verified written.
- **Recordings list:** a separate, resizable `Window`.

## Components

Each is a small unit with one purpose, a defined interface, and explicit dependencies.

### `AppSettings` (new) — `Settings/AppSettings.swift`
- **Purpose:** user preferences, persisted.
- **Interface:** `@Observable @MainActor`. `recordingsDirectory: URL` (default `URL.musicDirectory` + `audio-pipeline`), `outputFormat: OutputFormat` (default `.caf`). Setting either property persists to `UserDefaults` immediately.
- **Depends on:** `UserDefaults`, Foundation. The directory is stored as a path string — non-sandboxed app, so no security-scoped bookmark needed.

### `OutputFormat` (new) — in `AppSettings.swift`
- `enum OutputFormat: String, CaseIterable { case caf, flac, both }`, with display titles for the radio control.

### `RecordingStore` (modified) — `Storage/RecordingStore.swift`
- Change `init()` to `init(baseURL: URL)`; the caller passes `settings.recordingsDirectory`. Folder creation, ISO-8601 naming, and `revealInFinder()` are unchanged.

### `FLACExporter` (new) — `Audio/FLACExporter.swift`
- **Purpose:** convert one CAF track to a 16 kHz mono FLAC.
- **Interface:** `nonisolated static func export(from caf: URL, to flac: URL) async throws`.
- **How:** `AVAudioFile(forReading:)` the source; a target `AVAudioFile(forWriting:)` with `kAudioFormatFLAC`, 16 kHz, 1 channel, 16-bit; `AVAudioConverter` handles sample-rate conversion and down-mix; read/convert/write in chunks.
- **Depends on:** AVFoundation. Runs off the main actor.

### `RecordingsLibrary` (new) — `Storage/RecordingsLibrary.swift`
- **Purpose:** the model behind the Recordings window.
- **Interface:** `@Observable @MainActor`. `recordings: [RecordingItem]` (read-only); `refresh()` rescans; `delete(_ item:)` removes the folder and rescans.
- **`refresh()`:** enumerate subfolders of `settings.recordingsDirectory`; per folder parse `meta.json`, detect which audio files exist, sum file sizes; sort by date descending.
- **`RecordingItem`:** `id` (folder name), `name`, `startedAt`, `duration`, `sizeBytes`, `tracks` (which of mic/system × caf/flac are present), `folderURL`.
- **Depends on:** `RecordingMetadata`, `FileManager`, `AppSettings`.

### `SettingsView` (new) — `UI/SettingsView.swift`
- A `Form`: recordings location (current path + "Choose…" → `NSOpenPanel` directory picker) and output format (`Picker` with `.radioGroup` style).
- **Depends on:** `AppSettings`.

### `RecordingsView` (new) — `UI/RecordingsView.swift`
- A `Table(library.recordings)` — columns: Name, Date, Duration, Size, Format.
- Row actions (context menu): **Play** (`NSWorkspace.open` the system track if present, else the mic track), **Reveal in Finder** (`activateFileViewerSelecting`), **Delete** (confirmation alert → `library.delete`).
- **Depends on:** `RecordingsLibrary`, AppKit.

### `audio_pipelineApp` (modified)
- Add `Settings { SettingsView() }` and `Window("Recordings", id: "recordings") { RecordingsView() }` scenes.
- Read `AppSettings` and `RecordingsLibrary` from the `AppCoordinator` and inject them into the Settings and Recordings views.

### `MenuBarContent` (modified)
- Add **"Recordings…"** (`openWindow(id: "recordings")`) and **"Settings…"** (`SettingsLink`).

### `AppCoordinator` (modified)
- Owns `AppSettings` and `RecordingsLibrary`; builds `RecordingStore(baseURL: settings.recordingsDirectory)`.
- After `RecordingSession.stop()`: if `outputFormat != .caf`, spawn a `Task` that runs `FLACExporter.export` for the mic and system tracks; on success, if mode is `flac`, delete the CAFs; then call `RecordingsLibrary.refresh()`.

## Data flow

- **Record → stop:** CAFs finalized → recording is done (status `idle`). If format ≠ `caf`, a background `Task` exports `mic.flac` + `system.flac`; on success in `flac` mode the CAFs are deleted; the library refreshes.
- **Settings → location change:** future recordings use the new path; the Recordings window shows the configured path.
- **Recordings window open:** `RecordingsLibrary.refresh()` scans the configured folder.

## Error handling

- **FLAC export fails:** the CAF is kept regardless of mode (never deleted on failure) — no data loss. The error is logged via `os.Logger` and surfaced in `AppCoordinator.lastError`.
- **Delete:** always behind a confirmation alert; removes the whole recording folder.
- **Recordings directory missing or unwritable:** `makeRecordingFolder` already throws, surfaced at record time. The Recordings window shows an empty list when the folder does not exist yet.

## Out of scope

- Migrating or moving existing recordings when the location changes.
- Rename, tag, or search in the Recordings window.
- The M2 `audio.convert` pipeline node (richer, separate).
- Configurable FLAC sample rate / bit depth — fixed at 16 kHz / 16-bit mono for M1.

## Testing

- No test target exists, and per `CLAUDE.md` one must be added through Xcode rather than by hand-editing `project.pbxproj` — so M1 verification is manual: record in each of the three format modes, confirm the expected files appear, confirm the Recordings window lists them with correct metadata, and confirm play / reveal / delete.
- `FLACExporter` is the natural first unit test if a test target is added later: a known CAF in, a 16 kHz mono FLAC of matching duration out.
