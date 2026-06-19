# App Sandbox Productionization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sandboxed app write recordings reliably to the default `~/Music/Amanuensis` and to any user-chosen folder, surviving relaunch, via security-scoped bookmarks.

**Architecture:** A pure policy (`AppSettings.needsSecurityScope`) decides whether a folder needs a bookmark (true iff outside `~/Music`). An app-side `RecordingsFolderAccess` owns the effective recordings URL and its security scope for the process lifetime: it resolves a persisted bookmark on launch, creates one when the user picks a non-Music folder, and falls back to the always-reachable `~/Music/Amanuensis` on any failure. `~/Music` paths skip bookmarks entirely (covered by the `assets.music.read-write` entitlement).

**Tech Stack:** Swift 6.2, App Sandbox, security-scoped URL bookmarks, Swift Testing (SPM) + XCTest (app-hosted), Developer ID signing.

**Branch:** `feat/app-sandbox` (sandbox already enabled here).

**Spec:** `docs/superpowers/specs/2026-06-18-app-sandbox-productionization-design.md`

---

## File Structure

- `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` — modify: rename default folder; add `recordingsDirectoryBookmark`; add static `needsSecurityScope`.
- `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift` — modify: tests for the above.
- `Amanuensis/Recordings/RecordingsFolderAccess.swift` — create: effective-URL + security-scope owner.
- `AmanuensisTests/RecordingsFolderAccessTests.swift` — create: app-hosted tests (no-bookmark resolve, bogus-bookmark fallback, select-under-Music).
- `Amanuensis/AppCoordinator.swift` — modify: own `RecordingsFolderAccess`, route reads through `effectiveURL`, add `selectRecordingsFolder`.
- `Amanuensis/UI/SettingsView.swift` — modify: picker calls `coordinator.selectRecordingsFolder`.
- `Amanuensis.xcodeproj/project.pbxproj` — modify: `ENABLE_USER_SELECTED_FILES = readwrite` (both app configs).

---

### Task 1: Rename default recordings folder to ~/Music/Amanuensis

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift:36-37`
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Add inside `@Suite struct AppSettingsBehavior`:

```swift
    @Test func defaultRecordingsDirectory_isUnderMusicNamedAmanuensis() {
        let dir = AppSettings.defaultRecordingsDirectory
        #expect(dir.lastPathComponent == "Amanuensis")
        #expect(dir.deletingLastPathComponent().standardizedFileURL
            == URL.musicDirectory.standardizedFileURL)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter defaultRecordingsDirectory_isUnderMusicNamedAmanuensis`
Expected: FAIL — `lastPathComponent` is `"audio-pipeline"`, not `"Amanuensis"`.

- [ ] **Step 3: Rename the default**

In `AppSettings.swift`, change lines 36-37:

```swift
    public static let defaultRecordingsDirectory: URL = URL.musicDirectory
        .appending(path: "Amanuensis", directoryHint: .isDirectory)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter defaultRecordingsDirectory_isUnderMusicNamedAmanuensis`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift
git commit -m "feat(sandbox): default recordings folder to ~/Music/Amanuensis"
```

---

### Task 2: `needsSecurityScope` pure policy

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` (add an extension at end of file)
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

Add a new suite in `AppSettingsTests.swift`:

```swift
@Suite struct NeedsSecurityScopePolicy {
    private let music = URL(filePath: "/Users/test/Music", directoryHint: .isDirectory)

    @Test func defaultAndMusicPaths_needNoScope() {
        let amanuensis = music.appending(path: "Amanuensis", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: amanuensis, musicDirectory: music) == false)
        #expect(AppSettings.needsSecurityScope(for: music, musicDirectory: music) == false)
        let nested = music.appending(path: "a/b", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: nested, musicDirectory: music) == false)
    }

    @Test func outsideMusic_needsScope() {
        let docs = URL(filePath: "/Users/test/Documents/Rec", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: docs, musicDirectory: music) == true)
    }

    @Test func siblingPrefix_needsScope() {
        // "/Users/test/MusicStuff" must NOT count as under "/Users/test/Music".
        let sibling = URL(filePath: "/Users/test/MusicStuff", directoryHint: .isDirectory)
        #expect(AppSettings.needsSecurityScope(for: sibling, musicDirectory: music) == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter NeedsSecurityScopePolicy`
Expected: FAIL — `needsSecurityScope` does not exist (compile error).

- [ ] **Step 3: Implement the policy**

Append to `AppSettings.swift` (after the closing `}` of the class):

```swift
extension AppSettings {
    // Pure policy: true iff `folder` is outside the Music folder and therefore
    // needs a security-scoped bookmark under App Sandbox. Paths at or under
    // ~/Music are covered directly by com.apple.security.assets.music.read-write.
    // Lexical comparison on standardized paths (no symlink resolution).
    nonisolated public static func needsSecurityScope(
        for folder: URL,
        musicDirectory: URL = .musicDirectory
    ) -> Bool {
        let f = folder.standardizedFileURL.path
        let m = musicDirectory.standardizedFileURL.path
        if f == m { return false }
        return !f.hasPrefix(m + "/")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter NeedsSecurityScopePolicy`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift
git commit -m "feat(sandbox): add needsSecurityScope folder policy"
```

---

### Task 3: Persist `recordingsDirectoryBookmark`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`
- Test: `Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Add inside `@Suite struct AppSettingsBehavior`:

```swift
    @Test func recordingsDirectoryBookmark_persistsAndClears() {
        withIsolatedDefaults { defaults in
            let data = Data([0x01, 0x02, 0x03])

            let first = AppSettings(defaults: defaults)
            #expect(first.recordingsDirectoryBookmark == nil)
            first.recordingsDirectoryBookmark = data

            let second = AppSettings(defaults: defaults)
            #expect(second.recordingsDirectoryBookmark == data)

            second.recordingsDirectoryBookmark = nil
            let third = AppSettings(defaults: defaults)
            #expect(third.recordingsDirectoryBookmark == nil)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter recordingsDirectoryBookmark_persistsAndClears`
Expected: FAIL — `recordingsDirectoryBookmark` does not exist (compile error).

- [ ] **Step 3: Add the stored property + key + load**

In `AppSettings.swift`, add the property after `recordingsDirectory`'s closing `}` (after line 13):

```swift
    // Security-scoped bookmark for a recordings folder outside ~/Music. nil when
    // the folder is the default or under ~/Music (asset-entitlement covered).
    public var recordingsDirectoryBookmark: Data? {
        didSet {
            if let data = recordingsDirectoryBookmark {
                defaults.set(data, forKey: Keys.recordingsDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.recordingsDirectoryBookmark)
            }
        }
    }
```

In `init`, after the `recordingsDirectory` if/else block (after line 46), add:

```swift
        recordingsDirectoryBookmark = defaults.data(forKey: Keys.recordingsDirectoryBookmark)
```

In the `Keys` enum, add:

```swift
        static let recordingsDirectoryBookmark = "recordingsDirectoryBookmark"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter recordingsDirectoryBookmark_persistsAndClears`
Expected: PASS.

- [ ] **Step 5: Run the full AppSettings suite (no regressions)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppSettings`
Expected: PASS (all AppSettings tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift Packages/AudioPipeline/Tests/AppSettingsTests/AppSettingsTests.swift
git commit -m "feat(sandbox): persist recordingsDirectoryBookmark in AppSettings"
```

---

### Task 4: `RecordingsFolderAccess` (effectful edge)

**Files:**
- Create: `Amanuensis/Recordings/RecordingsFolderAccess.swift`
- Test: `AmanuensisTests/RecordingsFolderAccessTests.swift`

> Note: `Amanuensis/` is a `PBXFileSystemSynchronizedRootGroup`, so new files under it (and the new `Recordings/` subfolder) are auto-registered — no pbxproj edit. `AmanuensisTests/` is NOT synchronized; if Xcode doesn't pick up the new test file, it must be added to the test target (see CLAUDE.md `setup-tests.rb`).

- [ ] **Step 1: Write the implementation**

Create `Amanuensis/Recordings/RecordingsFolderAccess.swift`:

```swift
import AppKit
import AppSettings
import os

// Owns the effective recordings-folder URL and its security-scoped access for
// the process lifetime. Folders outside ~/Music are only reachable through a
// security-scoped bookmark; ~/Music is covered by assets.music.read-write. The
// default ~/Music/Amanuensis is the universal fallback whenever a bookmark fails.
@MainActor
final class RecordingsFolderAccess {
    private let settings: AppSettings
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "recordings-folder")

    // URL currently usable for writes (security scope already started if needed).
    private(set) var effectiveURL: URL

    private var activeScopedURL: URL?

    init(settings: AppSettings) {
        self.settings = settings
        self.effectiveURL = settings.recordingsDirectory
        resolveOnLaunch()
    }

    private func resolveOnLaunch() {
        guard let data = settings.recordingsDirectoryBookmark else {
            effectiveURL = settings.recordingsDirectory  // default / ~/Music, asset-covered
            return
        }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                log.error("startAccessingSecurityScopedResource failed; falling back to default")
                effectiveURL = AppSettings.defaultRecordingsDirectory
                return
            }
            activeScopedURL = url
            effectiveURL = url
            if stale, let fresh = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
            ) {
                settings.recordingsDirectoryBookmark = fresh
            }
        } catch {
            log.error("bookmark resolve failed: \(String(describing: error), privacy: .public)")
            effectiveURL = AppSettings.defaultRecordingsDirectory
        }
    }

    // Called from the Settings folder picker after the user chooses a folder.
    func select(_ url: URL) {
        stopActiveScope()
        if AppSettings.needsSecurityScope(for: url) {
            do {
                let data = try url.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
                )
                settings.recordingsDirectoryBookmark = data
                if url.startAccessingSecurityScopedResource() {
                    activeScopedURL = url
                }
            } catch {
                log.error("bookmark create failed: \(String(describing: error), privacy: .public)")
                settings.recordingsDirectoryBookmark = nil
            }
        } else {
            settings.recordingsDirectoryBookmark = nil
        }
        settings.recordingsDirectory = url
        effectiveURL = url
    }

    func teardown() { stopActiveScope() }

    private func stopActiveScope() {
        if let url = activeScopedURL {
            url.stopAccessingSecurityScopedResource()
            activeScopedURL = nil
        }
    }
}
```

- [ ] **Step 2: Write the app-hosted tests**

Create `AmanuensisTests/RecordingsFolderAccessTests.swift`:

```swift
import XCTest
import AppSettings
@testable import Amanuensis

@MainActor
final class RecordingsFolderAccessTests: XCTestCase {
    private func isolatedSettings() -> (AppSettings, String) {
        let suite = "RecordingsFolderAccessTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), suite)
    }

    func test_noBookmark_usesRecordingsDirectoryAsIs() {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let dir = URL.musicDirectory.appending(path: "Amanuensis", directoryHint: .isDirectory)
        settings.recordingsDirectory = dir

        let access = RecordingsFolderAccess(settings: settings)
        XCTAssertEqual(access.effectiveURL.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_bogusBookmark_fallsBackToDefault() {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settings.recordingsDirectory = URL(filePath: "/tmp/should-not-be-used", directoryHint: .isDirectory)
        settings.recordingsDirectoryBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let access = RecordingsFolderAccess(settings: settings)
        XCTAssertEqual(access.effectiveURL.standardizedFileURL,
                       AppSettings.defaultRecordingsDirectory.standardizedFileURL)
    }

    func test_selectUnderMusic_storesNoBookmark() {
        let (settings, suite) = isolatedSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let access = RecordingsFolderAccess(settings: settings)
        let dir = URL.musicDirectory.appending(path: "Amanuensis", directoryHint: .isDirectory)

        access.select(dir)
        XCTAssertNil(settings.recordingsDirectoryBookmark)
        XCTAssertEqual(access.effectiveURL.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(settings.recordingsDirectory.standardizedFileURL, dir.standardizedFileURL)
    }
}
```

> The real scoped-bookmark round-trip (picking a folder outside `~/Music`) needs a powerbox grant and is covered by the manual checklist in Task 7, not here.

- [ ] **Step 3: Run the app-hosted tests**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' -only-testing:AmanuensisTests/RecordingsFolderAccessTests test`
Expected: PASS (3 tests). If the build reports the test file isn't in the target, add it per CLAUDE.md (`scripts/setup-tests.rb` is add-only) and re-run.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/Recordings/RecordingsFolderAccess.swift AmanuensisTests/RecordingsFolderAccessTests.swift
git commit -m "feat(sandbox): add RecordingsFolderAccess with bookmark resolution"
```

---

### Task 5: Wire `RecordingsFolderAccess` into the app

**Files:**
- Modify: `Amanuensis/AppCoordinator.swift` (lines 45-51, 67-70, 163, 241)
- Modify: `Amanuensis/UI/SettingsView.swift:57-59`

- [ ] **Step 1: Declare the property**

In `AppCoordinator.swift`, add to the `let` block near line 45-51:

```swift
    let folderAccess: RecordingsFolderAccess
```

- [ ] **Step 2: Construct it and route the library through it**

In `init`, replace line 70:

```swift
        self.library = RecordingsLibrary { settings.recordingsDirectory }
```

with:

```swift
        let folderAccess = RecordingsFolderAccess(settings: settings)
        self.folderAccess = folderAccess
        self.library = RecordingsLibrary { folderAccess.effectiveURL }
```

- [ ] **Step 3: Route the recording store and open-folder action**

Replace line 163:

```swift
            let store = RecordingStore(baseURL: settings.recordingsDirectory)
```

with:

```swift
            let store = RecordingStore(baseURL: folderAccess.effectiveURL)
```

Replace line 241:

```swift
        let url = settings.recordingsDirectory
```

with:

```swift
        let url = folderAccess.effectiveURL
```

- [ ] **Step 4: Add the selection entry point**

In `AppCoordinator.swift`, add a method (e.g. near the other recording methods):

```swift
    func selectRecordingsFolder(_ url: URL) {
        folderAccess.select(url)
        Task { await library.refresh() }
    }
```

> `RecordingsLibrary.refresh()` is `async` (it's the same method `AppCoordinator` already calls at lines 202/235); the `Task` re-scans at the new `effectiveURL` from this `@MainActor` context.

- [ ] **Step 5: Point the Settings picker at the coordinator**

In `SettingsView.swift`, replace lines 57-59:

```swift
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingsDirectory = url
        }
```

with:

```swift
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.selectRecordingsFolder(url)
        }
```

- [ ] **Step 6: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `"exit" : 0`.

- [ ] **Step 7: Commit**

```bash
git add Amanuensis/AppCoordinator.swift Amanuensis/UI/SettingsView.swift
git commit -m "feat(sandbox): route recordings folder through RecordingsFolderAccess"
```

---

### Task 6: Enable read-write user-selected files

**Files:**
- Modify: `Amanuensis.xcodeproj/project.pbxproj` (both app-target configs)

> Privileged pbxproj edit. Both app configs currently have `ENABLE_USER_SELECTED_FILES = readonly;`.

- [ ] **Step 1: Flip the build setting**

In `project.pbxproj`, change both occurrences of:

```
				ENABLE_USER_SELECTED_FILES = readonly;
```

to:

```
				ENABLE_USER_SELECTED_FILES = readwrite;
```

(There are exactly two — Debug and Release of the app target. The test target has none.)

- [ ] **Step 2: Build and verify the embedded entitlement**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `"exit" : 0`.

Then read the regenerated `.xcent` from the build log (path ends `Amanuensis.app.xcent`) and confirm:
```
"com.apple.security.files.user-selected.read-write" => true
```
(replacing the previous `…read-only`).

- [ ] **Step 3: Commit**

```bash
git add Amanuensis.xcodeproj/project.pbxproj
git commit -m "feat(sandbox): ENABLE_USER_SELECTED_FILES read-write for folder picker"
```

---

### Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: SPM suite green**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: all suites pass (existing 308 + the new AppSettings/policy tests).

- [ ] **Step 2: App target builds**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `"exit" : 0`.

- [ ] **Step 2b: App-hosted tests pass**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' test`
Expected: pass. (If injection fails under Hardened Runtime, that's the known test-target-signing follow-up — note it, don't fix here.)

- [ ] **Step 3: Manual checklist** (run the built app from `~/Library/Developer/Xcode/DerivedData/Amanuensis-*/Build/Products/Debug/Amanuensis.app`)

  - [ ] Fresh container: default `~/Music/Amanuensis` records with **no folder prompt**; the file has audio.
  - [ ] Settings → Choose `~/Documents/<x>`; record; **quit and relaunch**; record again → recordings still write to that folder (bookmark resolved).
  - [ ] Re-point at the old `~/Music/audio-pipeline`; works (asset-covered, no bookmark).
  - [ ] **Keychain (D2):** confirm whether stored API keys still resolve after the signing change, or need a one-time re-entry. Record the result.

- [ ] **Step 4: Final commit (if any checklist fixes were needed)**

```bash
git add -A
git commit -m "test(sandbox): verification pass for folder access"
```

---

## Self-Review

- **Spec coverage:** D1 manual migration (no code — documented, Task 7 keychain check) ✓; D2 keychain re-entry (Task 7 manual) ✓; D3 Approach X (Task 2 policy + Task 4 access) ✓; D4 rename (Task 1) ✓; D5 readwrite entitlement (Task 6) ✓; D6 pure/effectful split (Task 2 pure, Task 4 effectful) ✓; D7 default fallback (Task 4 `resolveOnLaunch` + `catch`) ✓.
- **Types consistent:** `needsSecurityScope(for:musicDirectory:)`, `recordingsDirectoryBookmark`, `RecordingsFolderAccess.effectiveURL`/`select`/`teardown`, `selectRecordingsFolder` used identically across tasks. `RecordingsLibrary.refresh()` confirmed `async` (matches existing AppCoordinator usage).
