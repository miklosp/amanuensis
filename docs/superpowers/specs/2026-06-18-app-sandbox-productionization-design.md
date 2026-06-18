# App Sandbox productionization — design

**Date:** 2026-06-18
**Status:** Approved (brainstorming)
**Scope:** Make the already-sandboxed app fully usable — recordings write
reliably to the default `~/Music/Amanuensis` and to any user-chosen folder,
surviving relaunch. Distribution path is Developer ID (the system-audio process
tap needs the private `kTCCServiceAudioCapture` SPI, a hard Mac App Store
blocker). Mac App Store distribution is explicitly out of scope.

## Goal

App Sandbox is already enabled on the `feat/app-sandbox` branch
(`ENABLE_APP_SANDBOX = YES`, entitlements `app-sandbox` + `device.audio-input` +
`assets.music.read-write`), and the app is signed with a stable Developer ID
identity (team `V378YWVH44`, on `main`). The system-audio tap was verified to
deliver real audio under the sandbox.

What's left is making the app *usable* sandboxed: today, recordings only write
under `~/Music` (via the asset entitlement), and the recordings-folder picker
still lets the user choose arbitrary directories that the sandbox then blocks.
This spec closes that gap with security-scoped bookmarks, and renames the stale
default folder.

## Current state

- **Recordings location** — `AppSettings.recordingsDirectory`
  (`Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`) is a `URL`
  persisted to `UserDefaults.standard` as a path string. Default is
  `AppSettings.defaultRecordingsDirectory = URL.musicDirectory.appending(path:
  "audio-pipeline")` — a stale name from before the app rename.
- **Folder picker** — `SettingsView` (`Amanuensis/UI/SettingsView.swift:109`)
  runs an `NSOpenPanel` with `canChooseDirectories = true` and assigns the
  result to `settings.recordingsDirectory`. No security-scoped bookmark is
  created, so a chosen folder is inaccessible after relaunch (and under the
  current `ENABLE_USER_SELECTED_FILES = readonly`, not writable at all).
- **Consumers** — `AppCoordinator` builds `RecordingsLibrary { settings.recordingsDirectory }`
  and `RecordingStore(baseURL: settings.recordingsDirectory)`.
- **App data** — `ProvidersStore`/`JobsStore` persist to
  `Application Support/work.miklos.amanuensis/{providers,jobs}.json` via
  `FileManager.url(for: .applicationSupportDirectory)`, which the sandbox
  redirects into the app container. `AppSettings` uses `UserDefaults.standard`,
  also container-redirected. `KeychainStore` uses a service string with no
  explicit access group.

## Decisions

- **D1 — Migration is clean-break; no migration code.** A sandboxed app cannot
  read the legacy unsandboxed `~/Library/Application Support/…` path, and we
  will not add a temporary-exception entitlement to reach it. The sandboxed app
  starts with empty providers/jobs and default settings. Escape hatch
  (documented, manual, run from outside the sandbox while the app is quit):
  ```
  DEST="$HOME/Library/Containers/work.miklos.amanuensis/Data/Library/Application Support/work.miklos.amanuensis"
  cp "$HOME/Library/Application Support/work.miklos.amanuensis/"{providers,jobs}.json "$DEST/"
  ```
  `apiKeyRef` in `providers.json` is a Keychain *reference*, so it resolves
  after copying — no secrets are in the JSON. Settings (`UserDefaults`) are
  re-entered, not copied (`cfprefsd` caches them).
- **D2 — Keychain: expect a one-time re-entry, then stable.** Keychain is not
  redirected by the sandbox (same team + bundle ID = same access group), so
  keys persist across the sandbox toggle. But the earlier ad-hoc → Developer ID
  signing change likely already moved the access group, so API keys may need
  re-entering once. Verified empirically in the test pass, not handled in code.
- **D3 — Approach X: Music-default + bookmarks for custom folders.** Keep the
  `assets.music.read-write` entitlement so the default `~/Music/Amanuensis`
  works with zero friction (no bookmark, no prompt). Only folders *outside*
  `~/Music` use a security-scoped bookmark. Rejected Approach Y (drop the asset
  entitlement, bookmark everything) — it forces a first-run folder pick for the
  default and buys entitlement purity we don't need on Developer ID.
- **D4 — Default folder renamed to `~/Music/Amanuensis`.** Old recordings under
  `~/Music/audio-pipeline` are left in place (both are `~/Music`, asset-covered);
  the user can re-point the picker at them. Not migrated.
- **D5 — `ENABLE_USER_SELECTED_FILES = readwrite`.** Required so a panel-chosen
  folder is writable. Both app build configs. Only build-setting change.
- **D6 — Pure policy / effectful edge split.** Mirrors the existing
  `MicCuePolicy` (pure, SPM, unit-tested) vs effectful-app-side pattern. The
  "does this folder need a bookmark?" decision is pure; the bookmark
  create/resolve/start/stop dance is an app-side effectful type.
- **D7 — Default is the universal fallback.** `~/Music/Amanuensis` is always
  reachable via the asset entitlement, so any bookmark failure (stale,
  unresolvable, access denied) falls back to it rather than leaving the app with
  no writable location.

## Components

### `needsSecurityScope` — pure policy (SPM, `AppSettings` module)

Lives beside `defaultRecordingsDirectory` in the `AppSettings` module, which
already owns the Music-folder default; `RecordingsFolderAccess` imports it.

```swift
// true iff `folder` is outside the Music folder (and therefore needs a
// security-scoped bookmark under App Sandbox). Paths under ~/Music are covered
// directly by com.apple.security.assets.music.read-write.
func needsSecurityScope(_ folder: URL, musicDirectory: URL) -> Bool
```

Deterministic, Foundation-only, unit-tested. Compares standardized file paths
(`url.standardizedFileURL.path`) — `folder` is under `musicDirectory` when its
path equals or is prefixed by `musicDirectory`'s path + `/`.

### `RecordingsFolderAccess` — effectful edge (app-side)

Owns the effective recordings-folder URL and its security scope for the process
lifetime. Single responsibility: turn the persisted (path, bookmark?) into a
usable, access-started URL, and manage scope teardown.

- `init` / `resolveOnLaunch()` →
  - bookmark present: `URL(resolvingBookmarkData:options:.withSecurityScope,
    bookmarkDataIsStale:&stale)`, then `startAccessingSecurityScopedResource()`.
    If `stale` and the URL still resolves, recreate + re-persist the bookmark.
    On any failure, fall back to `defaultRecordingsDirectory` (D7) and surface a
    notice.
  - no bookmark: use the stored path directly (asset-covered).
- `select(_ url: URL)` (called from the picker): if `needsSecurityScope(url)`,
  create `url.bookmarkData(options: .withSecurityScope, …)` and persist it; else
  clear the stored bookmark. Persist the display path. Stop the previous scope,
  start the new one if scoped.
- `teardown()` / `deinit`: `stopAccessingSecurityScopedResource()` on the active
  scoped URL. Called on app termination and before switching folders.

Exposes the current effective `URL` to `AppCoordinator`, which keeps building
`RecordingsLibrary` / `RecordingStore` from it as today.

### `AppSettings` change

- Rename default: `defaultRecordingsDirectory` →
  `URL.musicDirectory.appending(path: "Amanuensis")`.
- Add `recordingsDirectoryBookmark: Data?` persisted to `UserDefaults`
  (key `recordingsDirectoryBookmark`), set/cleared by `RecordingsFolderAccess`.
  `recordingsDirectory` (path) stays as the human-readable display value.

### `SettingsView` wiring

The existing `NSOpenPanel` picker stays. Its completion routes the chosen URL
through `RecordingsFolderAccess.select(_:)` instead of assigning
`settings.recordingsDirectory` directly. The row keeps showing the current
folder path.

## Data flow

1. **Launch:** `AppCoordinator` creates `RecordingsFolderAccess`, which reads
   `(recordingsDirectory, recordingsDirectoryBookmark)` from `AppSettings`,
   resolves to an access-started effective URL, and hands it to
   `RecordingsLibrary` / `RecordingStore`.
2. **Pick a folder:** `SettingsView` panel → `RecordingsFolderAccess.select` →
   bookmark created iff outside `~/Music`, persisted; scope swapped; effective
   URL updated; consumers rebuilt.
3. **Record:** `RecordingStore` writes under the effective URL (scope already
   active). No per-write scope churn.
4. **Quit:** `RecordingsFolderAccess.teardown()` stops the scope.

## Error handling

- Stale bookmark, still resolvable → recreate + persist, continue.
- Stale/unresolvable, access denied, or `startAccessingSecurityScopedResource()`
  returns `false` → fall back to `~/Music/Amanuensis` (D7) + surface a notice.
- Chosen folder later deleted → `RecordingStore.createDirectory` fails with the
  existing "Couldn't create recording folder" error path.

## Testing

- **SPM (pure):** `needsSecurityScope` — folder exactly `~/Music`, nested under
  `~/Music`, sibling outside `~/Music`, a symlinked path, and the default.
- **App-hosted XCTest (`AmanuensisTests`):** bookmark round-trip against a temp
  directory — create `.withSecurityScope` bookmark → persist → resolve →
  `start`/`stop`. Gate on a runtime probe if security-scoped bookmarks aren't
  exercisable in the harness (cf. the `FileManager.trashItem` probe pattern).
- **Manual checklist:**
  - Default `~/Music/Amanuensis` records with no prompt on a fresh container.
  - Pick `~/Documents/<x>`; record; quit; relaunch → recordings still write.
  - Re-point at the old `~/Music/audio-pipeline`; works (asset-covered).
  - Verify whether API keys need one-time re-entry after the signing change (D2).

## Out of scope

- `AmanuensisTests` target signing under Hardened Runtime (separate follow-up).
- Any data-migration code (D1 is manual/clean-break).
- Mac App Store distribution (private TCC SPI blocks it).
