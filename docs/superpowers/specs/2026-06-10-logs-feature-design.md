# Logs Feature — Design

**Date:** 2026-06-10
**Status:** Approved (brainstorm)
**Scope:** New `AppLog` SPM target (`LogEntry`, `LogStore`) + a new `LogsView` and `.logs` sidebar destination in the app target + instrumentation in `AppCoordinator`.

## Goal

Add a **Logs** view alongside Recordings / Jobs / Providers showing a persistent, human-readable record of what the app has been doing: jobs started/succeeded/failed and recording lifecycle (started, stopped, conversion succeeded/failed), with severity levels (info / warning / error).

Today the only feedback is transient: `AppCoordinator` flashes a `jobActivity` / `recordingActivity` footer line that auto-clears after ~3s, and writes to `os.Logger` (visible only in Console.app, awkward under App Sandbox). There is no in-app history a user can scroll back through. This feature adds one.

## Non-goals

- **No handler-internal events in v1.** Events that happen inside the SPM handlers — e.g. the oversize-audio compression in `ChatCompletionsAudioHandler`, multipart upload progress — are not visible at the `AppCoordinator` boundary and are not surfaced. Adding them later means threading a logging sink into the handlers; explicitly deferred.
- **No level/category filtering UI** (YAGNI). The list is chronological; filtering can be added later.
- **No `os.Logger` removal.** Existing `Self.log.*` calls stay as developer diagnostics; the `LogStore` is a separate user-facing record.
- **No `OSLogStore` integration.** Reading back the unified log was considered and rejected — unreliable under App Sandbox, clunky to query/format, no clean way to attach levels/categories.
- **No log export / share / file reveal.** Just view + clear.

## New module: `AppLog`

Holds the model and store; pure, deterministic, SPM-testable like `AppSettings`/`RecordingStorage`. Recording- and job-sourced logs both flow through it, so it is its own cross-cutting module rather than living inside `AudioPipelineJobs`. It uses `mainActorSettings` (the `LogStore` is `@MainActor @Observable`).

Wiring is two steps:
1. **Manual `Package.swift` edit** — add `.library(name: "AppLog", targets: ["AppLog"])` to `products`, `.target(name: "AppLog", swiftSettings: mainActorSettings)` and `.testTarget(name: "AppLogTests", dependencies: ["AppLog"], swiftSettings: mainActorSettings)` to `targets`; create the `Sources/AppLog/` and `Tests/AppLogTests/` directories. The scaffold script does **not** touch `Package.swift`.
2. **`scripts/run-setup-spm-package.sh AppLog`** — links the (now-existing) `AppLog` product into the `audio-pipeline` app target's `package_product_dependencies` and Frameworks build phase. Idempotent.

### `LogEntry`

```swift
public struct LogEntry: Identifiable, Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public enum Category: String, Codable, Sendable { case job, recording }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: Category
    public let message: String

    public init(id: UUID = UUID(), date: Date, level: Level, category: Category, message: String)
}
```

`category` drives an at-a-glance row icon and is essentially free; `level` covers "warnings, errors"; `date` + `message` round it out.

### `LogStore`

```swift
@MainActor
@Observable
public final class LogStore {
    public private(set) var entries: [LogEntry] = []   // oldest → newest

    public init(fileURL: URL, limit: Int = 500) throws
    public static func standard(bundleID: String) throws -> LogStore

    public func log(_ level: LogEntry.Level, _ message: String, category: LogEntry.Category)
    public func clear()
}
```

- Same shape as `JobsStore`/`ProvidersStore`: `@MainActor @Observable`, JSON-on-disk at `Application Support/<bundleID>/logs.json`, atomic whole-file write on each mutation. Append frequency is per-event (seconds apart at most), so full-file rewrite cost is negligible.
- **Retention: `limit` (default 500) most-recent entries.** `log(…)` appends a `LogEntry` stamped with `Date()`, then trims the head so `entries.count <= limit`, then saves.
- `clear()` empties `entries` and persists.
- `load()` is best-effort: a missing file → empty; a corrupt/legacy file → empty (decode failure swallowed), so a bad `logs.json` never blocks launch. `AppCoordinator` wraps construction in the same temp-file fallback used for `JobsStore`/`ProvidersStore`.

## Instrumentation — all in `AppCoordinator`

A `let logs: LogStore` is added to `AppCoordinator`, constructed in `init()` with the existing `standard(bundleID:)` → temp-file fallback pattern. Existing `os.Logger` and `flashActivity` / `flashRecordingActivity` calls are untouched; a `logs.log(…)` is added beside each event below.

| Event | Site | Level | Category |
|---|---|---|---|
| Recording started | `startRecording` success | info | recording |
| System audio not authorized | `startRecording`, `!systemAudioGranted` | warning | recording |
| Recording start failed | `startRecording` catch | error | recording |
| Recording stopped | `stopRecording` after `active.stop()` | info | recording |
| Conversion succeeded | `stopRecording` task, `.success` | info | recording |
| Conversion failed | `stopRecording` task, `.failure` | error | recording |
| Job started | `runJob`, at "Running '…'" | info | job |
| Waiting for conversion before job | `runJob`, `isConverting` branch | warning | job |
| Job succeeded | `runJob`, `.success(out)` | info | job |
| Job failed — provider missing | `runJob` guard | error | job |
| Job failed — preset unknown | `runJob` guard | error | job |
| Job failed — combined.flac missing | `runJob` guard | error | job |
| Job failed — handler threw | `runJob` catch | error | job |

Messages reuse the wording already passed to the flash helpers (e.g. `"Done: '\(job.name)' → \(out.lastPathComponent)"`, `"Recording started in \(folder.name)"`) so the persistent log and the transient footer read consistently.

## UI

### Sidebar (`MainWindowView.swift`)

- Add `case logs` to `SidebarDestination`.
- Add `Label("Logs", systemImage: "list.bullet.rectangle").tag(SidebarDestination.logs)` to the existing "Library" `Section`, after Providers.
- `detail` switch gains `case .logs: LogsView(logs: coordinator.logs).navigationTitle("Logs")`.

### `LogsView.swift` (new, `audio-pipeline/UI/`)

- `List` of `logs.entries` rendered **newest-first** (reversed).
- Row: leading severity icon — info `info.circle` (blue/secondary), warning `exclamationmark.triangle` (yellow), error `xmark.octagon` (red); a category chip (`job` / `recording`); the message; trailing timestamp (`.dateTime` short, monospaced/secondary). One row = one `LogEntry`.
- Toolbar **Clear** button → `logs.clear()`.
- Empty state (`entries.isEmpty`): `ContentUnavailableView`-style "No activity yet."
- Read-only and dependency-injected (`let logs: LogStore`), consistent with `JobsView`/`ProvidersView`.

## Testing (SPM, `AppLogTests`)

- **Append + trim:** logging `limit + N` entries leaves exactly `limit`, retaining the most recent and dropping the oldest, in order.
- **Persistence round-trip:** entries written by one `LogStore` are read back by a second instance pointed at the same file (level, category, message, ordering preserved).
- **Clear:** `clear()` empties `entries` and the reloaded file is empty.
- **Corrupt/missing file:** constructing against a non-existent path yields empty `entries`; constructing against a file of garbage bytes yields empty `entries` (no throw).

`AppCoordinator` instrumentation is app-glue (MainActor, real stores) and is not unit-tested, consistent with the existing SPM-logic / app-hosted split.

## Files touched

- New: `Packages/AudioPipeline/Sources/AppLog/LogEntry.swift`
- New: `Packages/AudioPipeline/Sources/AppLog/LogStore.swift`
- New: `Packages/AudioPipeline/Tests/AppLogTests/LogStoreTests.swift`
- New: `audio-pipeline/UI/LogsView.swift`
- Modify: `Packages/AudioPipeline/Package.swift` (manually add `AppLog` library product, `AppLog` target, `AppLogTests` test target)
- Modify: `audio-pipeline.xcodeproj/project.pbxproj` (app target → `AppLog` link, via `scripts/run-setup-spm-package.sh AppLog`)
- Modify: `audio-pipeline/UI/MainWindowView.swift` (`.logs` destination, sidebar label, detail case)
- Modify: `audio-pipeline/AppCoordinator.swift` (`import AppLog`, `let logs`, init + fallback, `logs.log(…)` at each event site)
