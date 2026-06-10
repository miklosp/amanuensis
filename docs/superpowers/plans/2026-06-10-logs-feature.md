# Logs Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent, in-app **Logs** view alongside Recordings / Jobs / Providers that records job and recording lifecycle events with info/warning/error severity.

**Architecture:** A new `AppLog` SPM module holds a `LogEntry` model and an `@Observable LogStore` that persists the most recent 500 entries to `logs.json` in Application Support (same pattern as `JobsStore`). `AppCoordinator` — already the single point that observes every job/recording outcome — gains a `logs` store and calls `logs.log(…)` beside its existing `os.Logger`/flash-activity calls. A read-only `LogsView` renders the list; the sidebar gets a `.logs` destination.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftPM (local umbrella package), Observation, `@MainActor` default isolation, XCTest (SPM).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `Packages/AudioPipeline/Package.swift` | Declare `AppLog` product/target + `AppLogTests` | Modify |
| `Packages/AudioPipeline/Sources/AppLog/LogEntry.swift` | The log-entry value type (Codable model) | Create |
| `Packages/AudioPipeline/Sources/AppLog/LogStore.swift` | Persistent, trimmed, observable entry list | Create |
| `Packages/AudioPipeline/Tests/AppLogTests/LogStoreTests.swift` | Trim / persistence / clear / resilience tests | Create |
| `audio-pipeline.xcodeproj/project.pbxproj` | Link `AppLog` into the app target | Modify (via script) |
| `audio-pipeline/AppCoordinator.swift` | Own the store; instrument each event | Modify |
| `audio-pipeline/UI/LogsView.swift` | Render the entry list + Clear button | Create |
| `audio-pipeline/UI/MainWindowView.swift` | Sidebar destination + detail case | Modify |

**Conventions to honor while implementing:**
- The working tree already contains *unrelated* uncommitted changes (`JobRunner.swift`, `JobRunnerTests.swift`, `JobsView.swift`, `ProvidersView.swift`). **Every commit step uses an explicit `git add <paths>`** — never `git add -A`/`git add .` — so those files are not swept into these commits.
- SPM tests run with `--disable-sandbox` (required in this environment).
- The app target cannot be built with a bare `xcodebuild` here (`xcodebuild` self-refuses inside the sandbox). **Use the `xcode-build` skill** to build/test the app target — it routes through the outside-sandbox daemon. Where a task says "build the app", that means via the `xcode-build` skill (or Xcode ⌘B).
- Commit messages end with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## Task 1: Scaffold `AppLog` module and define `LogEntry`

**Files:**
- Modify: `Packages/AudioPipeline/Package.swift`
- Create: `Packages/AudioPipeline/Sources/AppLog/LogEntry.swift`

Adds only the library product + target (no test target yet — SwiftPM errors on a declared target whose source directory is missing, so `AppLogTests` is added in Task 2 together with its file).

- [ ] **Step 1: Add the `AppLog` product to `Package.swift`**

In `Packages/AudioPipeline/Package.swift`, add the product line after the `AudioPipelineJobs` library (line 22):

```swift
        .library(name: "AudioPipelineJobs", targets: ["AudioPipelineJobs"]),
        .library(name: "AppLog",            targets: ["AppLog"]),
```

- [ ] **Step 2: Add the `AppLog` target to `Package.swift`**

In the same file, add the target after the `AudioPipelineJobs` `.target(…)` block (after line 36, before the first `.testTarget`). `LogStore` is `@MainActor @Observable`, so it uses `mainActorSettings`:

```swift
        .target(name: "AppLog", swiftSettings: mainActorSettings),
```

- [ ] **Step 3: Create `LogEntry.swift`**

Create `Packages/AudioPipeline/Sources/AppLog/LogEntry.swift`:

```swift
import Foundation

// One row in the in-app activity log. Plain Codable value type; persisted as
// part of the LogStore's JSON array. `category` drives the row icon/chip in the
// UI, `level` the severity colouring.
public struct LogEntry: Identifiable, Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable {
        case info, warning, error
    }

    public enum Category: String, Codable, Sendable {
        case job, recording
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: Category
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date,
        level: Level,
        category: Category,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}
```

- [ ] **Step 4: Verify the module compiles**

Run: `swift build --package-path Packages/AudioPipeline 2>&1 | tail -20`
Expected: `Build complete!` (no errors). The `AppLog` target compiles.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Package.swift Packages/AudioPipeline/Sources/AppLog/LogEntry.swift
git commit -m "feat(logs): scaffold AppLog module with LogEntry model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `LogStore` — append/trim, persistence, clear, resilience

**Files:**
- Modify: `Packages/AudioPipeline/Package.swift` (add test target)
- Create: `Packages/AudioPipeline/Sources/AppLog/LogStore.swift`
- Test: `Packages/AudioPipeline/Tests/AppLogTests/LogStoreTests.swift`

- [ ] **Step 1: Add the `AppLogTests` test target to `Package.swift`**

In `Packages/AudioPipeline/Package.swift`, add after the `AudioPipelineJobsTests` `.testTarget(…)` block (after line 56):

```swift
        .testTarget(
            name: "AppLogTests",
            dependencies: ["AppLog"],
            swiftSettings: mainActorSettings
        ),
```

- [ ] **Step 2: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AppLogTests/LogStoreTests.swift`:

```swift
import XCTest
@testable import AppLog

@MainActor
final class LogStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
    }

    func testLogAppendsEntry() {
        let store = LogStore(fileURL: tempFile())
        store.log(.info, "hello", category: .job)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.message, "hello")
        XCTAssertEqual(store.entries.first?.level, .info)
        XCTAssertEqual(store.entries.first?.category, .job)
    }

    func testLogTrimsToLimitKeepingMostRecent() {
        let store = LogStore(fileURL: tempFile(), limit: 3)
        for i in 1...5 {
            store.log(.info, "entry \(i)", category: .job)
        }
        XCTAssertEqual(store.entries.count, 3)
        // Oldest two dropped; order preserved oldest -> newest.
        XCTAssertEqual(store.entries.map(\.message), ["entry 3", "entry 4", "entry 5"])
    }

    func testPersistenceRoundTrip() {
        let url = tempFile()
        let store = LogStore(fileURL: url)
        store.log(.warning, "first", category: .recording)
        store.log(.error, "second", category: .job)
        let captured = store.entries

        let reloaded = LogStore(fileURL: url)
        XCTAssertEqual(reloaded.entries, captured)
    }

    func testClearEmptiesAndPersists() {
        let url = tempFile()
        let store = LogStore(fileURL: url)
        store.log(.info, "x", category: .job)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)

        let reloaded = LogStore(fileURL: url)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    func testMissingFileYieldsEmpty() {
        let store = LogStore(fileURL: tempFile())  // path does not exist yet
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testCorruptFileYieldsEmpty() throws {
        let url = tempFile()
        try Data("not json".utf8).write(to: url)
        let store = LogStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppLogTests 2>&1 | tail -20`
Expected: FAIL — compile error, `cannot find 'LogStore' in scope`.

- [ ] **Step 4: Implement `LogStore`**

Create `Packages/AudioPipeline/Sources/AppLog/LogStore.swift`:

```swift
import Foundation
import Observation

// Persistent in-app activity log. JSON-on-disk in Application Support, same
// shape as JobsStore/ProvidersStore. Observable so LogsView re-renders as
// entries arrive. Keeps the most recent `limit` entries (oldest trimmed).
//
// `init(fileURL:)` is non-throwing: load() is best-effort, so a missing or
// corrupt file yields an empty log rather than a launch failure. The throwing
// surface is `standard(bundleID:)`, which can fail only on directory creation.
@MainActor
@Observable
public final class LogStore {
    public private(set) var entries: [LogEntry] = []  // oldest -> newest

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let limit: Int

    public init(fileURL: URL, limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = limit
        load()
    }

    // Constructs a LogStore at the standard app location:
    //   Application Support/<bundleID>/logs.json
    public static func standard(bundleID: String) throws -> LogStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LogStore(fileURL: dir.appendingPathComponent("logs.json"))
    }

    public func log(_ level: LogEntry.Level, _ message: String, category: LogEntry.Category) {
        entries.append(LogEntry(date: Date(), level: level, category: category, message: message))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    // Best-effort: missing file -> empty; unreadable/corrupt -> empty.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AppLogTests 2>&1 | tail -20`
Expected: PASS — all 6 tests in `AppLogTests` pass.

- [ ] **Step 6: Run the full SPM suite (no regressions)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline 2>&1 | tail -20`
Expected: all targets pass (`AppSettingsTests`, `RecordingStorageTests`, `RecordingCoreTests`, `AudioPipelineJobsTests`, `AppLogTests`).

- [ ] **Step 7: Commit**

```bash
git add Packages/AudioPipeline/Package.swift Packages/AudioPipeline/Sources/AppLog/LogStore.swift Packages/AudioPipeline/Tests/AppLogTests/LogStoreTests.swift
git commit -m "feat(logs): add persistent, trimmed LogStore

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Link `AppLog` into the app target

**Files:**
- Modify: `audio-pipeline.xcodeproj/project.pbxproj` (written by the script)

The `AppLog` product now exists in `Package.swift`; this links it into the `audio-pipeline` app target so the app code can `import AppLog`.

- [ ] **Step 1: Run the scaffold/link script**

Run: `scripts/run-setup-spm-package.sh AppLog`
Expected output includes:
```
local package Packages/AudioPipeline already registered
added product dependency AppLog to audio-pipeline
linked AppLog in audio-pipeline Frameworks phase
saved audio-pipeline.xcodeproj
```

- [ ] **Step 2: Verify the link landed in the pbxproj**

Run: `rg -c "AppLog" audio-pipeline.xcodeproj/project.pbxproj`
Expected: a count ≥ 3 (a `PBXBuildFile`, the `productName = AppLog;` dependency, and its Frameworks reference).

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline.xcodeproj/project.pbxproj
git commit -m "build(logs): link AppLog into the app target

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Own the `LogStore` in `AppCoordinator` and instrument events

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

No unit test — this is `@MainActor` app glue over real stores, consistent with the existing SPM-logic / app-hosted split. Verification is an app build at the end.

- [ ] **Step 1: Import `AppLog` and declare the stored property**

In `audio-pipeline/AppCoordinator.swift`, add the import (alphabetical, after `import AppSettings`, line 2):

```swift
import AppLog
```

Add the stored property to the store block (after `let providers: ProvidersStore`, line 49):

```swift
    let providers: ProvidersStore
    let logs: LogStore
```

- [ ] **Step 2: Initialize `logs` with the temp-file fallback**

In `init()`, after the `providers` initialization block closes (after line 100, the `}` of the providers `do/catch`, before the closing `}` of `init`), add:

```swift
        do {
            self.logs = try LogStore.standard(bundleID: "work.miklos.audio-pipeline")
        } catch {
            Self.log.error("failed to init logs store: \(String(describing: error), privacy: .public)")
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("logs-fallback.json")
            self.logs = LogStore(fileURL: tmp)
        }
```

- [ ] **Step 3: Instrument the recording lifecycle (`startRecording`)**

In `startRecording()`, in the system-audio guard, add the log line inside the existing `if`:

```swift
        if !systemAudioGranted {
            Self.log.error("system audio capture not authorized — system track will be silent")
            logs.log(.warning, "System audio not authorized — system track will be silent", category: .recording)
        }
```

In the success branch (after `Self.log.info("recording started in ...")`):

```swift
            _ = machine.sessionStarted()
            Self.log.info("recording started in \(folder.name, privacy: .public)")
            logs.log(.info, "Recording started in \(folder.name)", category: .recording)
```

In the `catch`:

```swift
        } catch {
            _ = machine.sessionFailed("Couldn't start recording: \(error.localizedDescription)")
            Self.log.error("start failed: \(String(describing: error), privacy: .public)")
            logs.log(.error, "Recording start failed: \(error.localizedDescription)", category: .recording)
        }
```

- [ ] **Step 4: Instrument the recording lifecycle (`stopRecording`)**

After the `Self.log.info("recording stopped …")` line (line 158), `folder` is in scope:

```swift
        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")
        logs.log(.info, "Recording stopped — \(folder.name)", category: .recording)
```

In the conversion-completion `Task`, log on each outcome. The closure captures `folderName`; add a log line to each branch of the `switch outcome.result`:

```swift
            switch outcome.result {
            case .success:
                result = .success(())
                flashMessage = "Recording ready"
                self.logs.log(.info, "Recording ready — \(folderName)", category: .recording)
            case .failure(let failure):
                result = .failure(failure)
                flashMessage = "Conversion failed: \(failure.message)"
                self.logs.log(.error, "Conversion failed: \(failure.message)", category: .recording)
            }
```

- [ ] **Step 5: Instrument the job lifecycle (`runJob`)**

In `runJob(_:on:)`, add a log line beside each `flashActivity` call.

Provider-missing guard:

```swift
        guard let providerID = job.providerID,
              let provider = providers.provider(id: providerID) else {
            await self.flashActivity("Failed: '\(job.name)' — provider missing")
            logs.log(.error, "Failed: '\(job.name)' — provider missing", category: .job)
            return .failure(JobRunError.providerMissing)
        }
```

Preset-unknown guard:

```swift
        guard let shape = presets.preset(id: provider.presetID)?.shape else {
            await self.flashActivity("Failed: '\(job.name)' — provider preset unknown")
            logs.log(.error, "Failed: '\(job.name)' — provider preset unknown", category: .job)
            return .failure(JobRunError.presetMissing)
        }
```

Waiting-for-conversion branch:

```swift
        if await conversionService.isConverting(folderName: recordingName) {
            withAnimation { jobActivity = "Waiting for '\(recordingName)' to finish converting…" }
            logs.log(.warning, "Waiting for '\(recordingName)' to finish converting before '\(job.name)'", category: .job)
            await conversionService.waitForConversion(folderName: recordingName)
        }
```

Job-started line (after the `withAnimation { jobActivity = "Running …" }`):

```swift
        withAnimation { jobActivity = "Running '\(job.name)' on '\(recordingName)'…" }
        logs.log(.info, "Running '\(job.name)' on '\(recordingName)'", category: .job)
```

combined.flac-missing guard:

```swift
        guard FileManager.default.fileExists(atPath: target.path) else {
            await self.flashActivity("Failed: '\(job.name)' — combined.flac missing")
            logs.log(.error, "Failed: '\(job.name)' — combined.flac missing", category: .job)
            return .failure(JobRunError.combinedFlacMissing)
        }
```

Success / failure of the run:

```swift
        do {
            let out = try await runner.run(job: job, provider: provider, shape: shape, audioURL: target)
            await self.flashActivity("Done: '\(job.name)' → \(out.lastPathComponent)")
            logs.log(.info, "Done: '\(job.name)' → \(out.lastPathComponent)", category: .job)
            return .success(out)
        } catch {
            Self.log.error("job '\(job.name, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
            await self.flashActivity("Failed: '\(job.name)' — \(error.localizedDescription)")
            logs.log(.error, "Failed: '\(job.name)' — \(error.localizedDescription)", category: .job)
            return .failure(error)
        }
```

- [ ] **Step 6: Build the app target**

Build via the `xcode-build` skill (Debug, `platform=macOS`).
Expected: BUILD SUCCEEDED. `AppCoordinator` compiles with the new store and instrumentation; nothing yet reads `coordinator.logs`, so the rest of the app is unaffected.

- [ ] **Step 7: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "feat(logs): record job and recording events in AppCoordinator

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `LogsView`

**Files:**
- Create: `audio-pipeline/UI/LogsView.swift`

Read-only view over `LogStore`, dependency-injected like `JobsView`/`ProvidersView`. New `.swift` files under `audio-pipeline/` are auto-picked-up by the synchronized group — no pbxproj edit needed.

- [ ] **Step 1: Create `LogsView.swift`**

Create `audio-pipeline/UI/LogsView.swift`:

```swift
import AppLog
import SwiftUI

struct LogsView: View {
    let logs: LogStore

    var body: some View {
        Group {
            if logs.entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Job and recording events will appear here.")
                )
            } else {
                List(logs.entries.reversed()) { entry in
                    LogRow(entry: entry)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear", systemImage: "trash") {
                    logs.clear()
                }
                .disabled(logs.entries.isEmpty)
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.callout)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(entry.category.rawValue.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                    Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.level {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch entry.level {
        case .info: .secondary
        case .warning: .yellow
        case .error: .red
        }
    }
}
```

- [ ] **Step 2: Build the app target**

Build via the `xcode-build` skill (Debug, `platform=macOS`).
Expected: BUILD SUCCEEDED. `LogsView` compiles (not yet referenced anywhere).

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/LogsView.swift
git commit -m "feat(logs): add LogsView list and Clear button

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire Logs into the sidebar

**Files:**
- Modify: `audio-pipeline/UI/MainWindowView.swift`

- [ ] **Step 1: Add the `.logs` destination case**

In `audio-pipeline/UI/MainWindowView.swift`, extend the enum (line 52-54):

```swift
enum SidebarDestination: Hashable {
    case recordings, jobs, providers, logs
}
```

- [ ] **Step 2: Add the sidebar label**

In the `Section("Library")` list, after the Providers label (line 17-18):

```swift
            Label("Providers", systemImage: "key")
                .tag(SidebarDestination.providers)
            Label("Logs", systemImage: "list.bullet.rectangle")
                .tag(SidebarDestination.logs)
```

- [ ] **Step 3: Add the detail case**

In the `detail:` `switch selection`, after the `.providers` case (line 37-41):

```swift
            case .providers:
                ProvidersView(presets: coordinator.presets,
                              providers: coordinator.providers,
                              keychain: coordinator.keychain)
                    .navigationTitle("Providers")
            case .logs:
                LogsView(logs: coordinator.logs)
                    .navigationTitle("Logs")
```

- [ ] **Step 4: Build the app target**

Build via the `xcode-build` skill (Debug, `platform=macOS`).
Expected: BUILD SUCCEEDED. The switch is now exhaustive over all four `SidebarDestination` cases.

- [ ] **Step 5: Manual smoke check**

Launch the app (`open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`, or ⌘R in Xcode). Verify:
- A **Logs** item appears under "Library", below Providers.
- Selecting it shows "No activity yet" on a clean store.
- Start + stop a recording → "Recording started…", "Recording stopped…", and "Recording ready…" rows appear (newest at top).
- Run a job → a "Running '…'" row then "Done: '…'" (or a red "Failed: …") row.
- **Clear** empties the list; relaunching the app keeps cleared/retained state (persistence).

- [ ] **Step 6: Commit**

```bash
git add audio-pipeline/UI/MainWindowView.swift
git commit -m "feat(logs): add Logs to the sidebar navigation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Spec Coverage Check

- **`LogEntry` (level/category/date/message)** → Task 1.
- **`LogStore` persisted to `logs.json`, 500-cap trim, `standard`/fallback, `clear`, corrupt/missing resilience** → Task 2 (logic + tests), Task 4 (fallback wiring in coordinator).
- **`AppLog` module wiring (Package.swift + app-target link)** → Tasks 1, 2, 3.
- **Instrumentation table (all 13 event sites)** → Task 4 (Steps 3-5).
- **Sidebar `.logs` destination + label + detail** → Task 6.
- **`LogsView` list (newest-first, icon/chip/timestamp), Clear, empty state** → Task 5.
- **SPM tests (append/trim, persistence, clear, corrupt, missing)** → Task 2.
- **Non-goals** (handler-internal events, filtering UI, `os.Logger` removal, `OSLogStore`, export) → none implemented, by omission.
