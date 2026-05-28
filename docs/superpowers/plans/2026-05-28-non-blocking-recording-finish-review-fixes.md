# Non-blocking recording finish — review fix-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address the three reviewer findings on PR #2 (`feat/non-blocking-recording-finish`): the `pendingConversion` clobber bug, the architecture-layer violation (pipeline logic inside `AppCoordinator`), and the synchronous `library.refresh()` on the main actor.

**Architecture:** Extract conversion orchestration into a new `RecordingConversionService` actor inside `Packages/AudioPipeline/Sources/RecordingCore/`. The service owns a `[String: Task<Outcome, Never>]` keyed by folder name (fixes the clobber), takes the combine operation as an injectable closure (testable), and performs source-CAF cleanup inside the conversion task (removes filesystem I/O from the app target). The `AppCoordinator` retains UI/state wiring only: spawning the service call, awaiting its result, updating the state machine, and refreshing the library. Separately, `RecordingsLibrary.refresh()` becomes `async` and dispatches its directory scan to a background task.

**Tech Stack:** Swift 6.2, Swift Concurrency (actors, `Task.detached`), Swift Testing (`@Test`, `#expect`). No new dependencies. Targets `RecordingCore` and `RecordingStorage` SPM packages plus the `audio-pipeline` app target.

---

## Background — read before starting

- **Reviewer findings:** see PR #2 comments on commit `fb8071a`. Two reviewers (Qodo, Macroscope) flag the `pendingConversion` clobber as a correctness bug. Qodo additionally flags the architecture-layer violation (rule 772232 / 772234) and the main-thread `library.refresh()`.
- **Prior design:** `docs/superpowers/specs/2026-05-27-non-blocking-recording-finish-design.md` §"Decisions" states "Single conversion at a time. The `RecorderStateMachine` already serializes via `.stopping`; one `pendingConversion` slot is enough." This assumption is **wrong**: the state machine returns to `.idle` on `sessionStopped(...)`, so a user can start a new recording while a previous conversion is still running. This plan replaces the single slot with a dictionary keyed by folder name.
- **Module boundary rule** (from `CLAUDE.md` and PR Compliance IDs 772232 / 772234): `audio-pipeline/` target holds only UI, the app entry point, and `AppCoordinator` composition wiring. Audio/storage/settings logic lives in `Packages/AudioPipeline/`.
- **Default actor isolation** is `MainActor` in the app target but `nonisolated` in `RecordingCore` (see `Packages/AudioPipeline/Package.swift`). `RecordingConversionService` must declare `actor` explicitly so its dictionary state is isolated to itself, not implicitly main.
- **Test runner:** SPM tests run via `swift test --disable-sandbox --package-path Packages/AudioPipeline`. The flag is required in this environment; see `CLAUDE.md` § Tests.

---

## File structure

**New files:**
- `Packages/AudioPipeline/Sources/RecordingCore/RecordingConversionService.swift` — the actor service.
- `Packages/AudioPipeline/Tests/RecordingCoreTests/RecordingConversionServiceTests.swift` — Swift Testing suite.
- `Packages/AudioPipeline/Tests/RecordingCoreTests/Support/SignalActor.swift` — small actor helper used by the service tests to pause a fake combine closure mid-flight.

**Modified files:**
- `audio-pipeline/AppCoordinator.swift` — replace the inline `Task.detached` + `pendingConversion` slot with `service.startConversion(...)`; remove the nested `PendingConversion` struct; route `runJob`'s wait through `service.waitForConversion`; remove the inline `FileManager.removeItem` for CAFs (now inside the service).
- `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift` — `refresh()` becomes `async`; the directory enumeration + `RecordingItem` construction moves to a `Task.detached`. `delete()` also becomes `async`.
- `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingsLibraryTests.swift` — update existing tests to `async` and `await library.refresh()`.
- `audio-pipeline/UI/RecordingsView.swift` — wrap the three `library.refresh()` / `library.delete(...)` callsites in `Task { ... }` (or `.task { ... }` for `.onAppear`).

**Unchanged (deliberately):**
- `RecorderStateMachine.swift` — the design choice to keep the lifecycle at `.idle` while conversion runs is preserved (matches the original spec's user intent: stop a recording, start another immediately).
- `CombinedFLACExporter.swift` — keeps its current signature; the service consumes it via the default combine closure.
- `RecordingSession.swift`, `AudioFileWriter.swift`, `MicRecorder.swift`, `ProcessTapRecorder.swift` — out of scope for this fix-up.

---

## Task 1: Add SignalActor test helper

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/Support/SignalActor.swift`

Small reusable helper used by the next task's tests. It lets a test pause a fake combine operation, observe in-flight state, then release the operation.

- [ ] **Step 1: Write the helper**

```swift
import Foundation

// Test helper. Lets a test pause an `await wait()` call until another task calls
// `fire()`. Used to hold a fake conversion mid-flight while assertions run.
actor SignalActor {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
```

- [ ] **Step 2: Confirm the package still builds**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS. Nothing references the helper yet; this just validates the file is well-formed.

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Tests/RecordingCoreTests/Support/SignalActor.swift
git commit -m "test: add SignalActor helper for pausing async fakes"
```

---

## Task 2: Create `RecordingConversionService` (failing tests first)

**Files:**
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/RecordingConversionServiceTests.swift`

Write the tests before the implementation. These lock in the API and the dictionary-tracking semantics that fix the clobber bug.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import RecordingCore

@Suite struct RecordingConversionServiceTests {

    @Test func twoConcurrentConversions_doNotClobberEachOther() async throws {
        let signalA = SignalActor()
        let signalB = SignalActor()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "conv-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = RecordingConversionService { mic, _, destination in
            if mic.lastPathComponent.hasPrefix("a") {
                await signalA.wait()
            } else {
                await signalB.wait()
            }
            try Data().write(to: destination)
        }

        let micA = tmp.appending(path: "a-mic.caf")
        let micB = tmp.appending(path: "b-mic.caf")
        try Data().write(to: micA)
        try Data().write(to: micB)
        let destA = tmp.appending(path: "a-combined.flac")
        let destB = tmp.appending(path: "b-combined.flac")

        let taskA = await service.startConversion(
            folderName: "a", mic: micA, system: nil,
            destination: destA, keepSourcesOnSuccess: true
        )
        let taskB = await service.startConversion(
            folderName: "b", mic: micB, system: nil,
            destination: destB, keepSourcesOnSuccess: true
        )

        #expect(await service.isConverting(folderName: "a"))
        #expect(await service.isConverting(folderName: "b"))

        await signalA.fire()
        let outcomeA = await taskA.value
        #expect(outcomeA.folderName == "a")
        if case .failure(let err) = outcomeA.result {
            Issue.record("A unexpectedly failed: \(err.message)")
        }
        #expect(await service.isConverting(folderName: "a") == false)
        // The fix: A's completion must NOT have cleared B's slot.
        #expect(await service.isConverting(folderName: "b") == true)

        await signalB.fire()
        let outcomeB = await taskB.value
        #expect(outcomeB.folderName == "b")
        #expect(await service.isConverting(folderName: "b") == false)
    }

    @Test func waitForConversion_returnsWhenTaskCompletes() async throws {
        let signal = SignalActor()
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "conv-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let service = RecordingConversionService { _, _, destination in
            await signal.wait()
            try Data().write(to: destination)
        }

        let mic = tmp.appending(path: "mic.caf")
        try Data().write(to: mic)
        let dest = tmp.appending(path: "combined.flac")

        _ = await service.startConversion(
            folderName: "rec", mic: mic, system: nil,
            destination: dest, keepSourcesOnSuccess: true
        )

        // Kick off a waiter; it should not return until we fire the signal.
        let waiter = Task { await service.waitForConversion(folderName: "rec") }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(waiter.isCancelled == false)
        // Heuristic: the waiter is still running because the conversion hasn't
        // finished. (We can't assert "not yet returned" directly; the value
        // check below covers it: if it had returned early, isConverting would
        // already be false here.)
        #expect(await service.isConverting(folderName: "rec"))

        await signal.fire()
        await waiter.value
        #expect(await service.isConverting(folderName: "rec") == false)
    }

    @Test func waitForConversion_returnsImmediately_whenNothingPending() async {
        let service = RecordingConversionService { _, _, destination in
            try Data().write(to: destination)
        }
        // Should return without throwing or hanging.
        await service.waitForConversion(folderName: "missing")
    }

    @Test func successfulConversion_deletesSources_whenKeepIsFalse() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "conv-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mic = tmp.appending(path: "mic.caf")
        let system = tmp.appending(path: "system.caf")
        let dest = tmp.appending(path: "combined.flac")
        try Data("mic".utf8).write(to: mic)
        try Data("sys".utf8).write(to: system)

        let service = RecordingConversionService { _, _, destination in
            try Data("flac".utf8).write(to: destination)
        }

        let task = await service.startConversion(
            folderName: "rec", mic: mic, system: system,
            destination: dest, keepSourcesOnSuccess: false
        )
        _ = await task.value

        #expect(FileManager.default.fileExists(atPath: mic.path) == false)
        #expect(FileManager.default.fileExists(atPath: system.path) == false)
        #expect(FileManager.default.fileExists(atPath: dest.path) == true)
    }

    @Test func successfulConversion_keepsSources_whenKeepIsTrue() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "conv-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mic = tmp.appending(path: "mic.caf")
        let dest = tmp.appending(path: "combined.flac")
        try Data("mic".utf8).write(to: mic)

        let service = RecordingConversionService { _, _, destination in
            try Data("flac".utf8).write(to: destination)
        }

        let task = await service.startConversion(
            folderName: "rec", mic: mic, system: nil,
            destination: dest, keepSourcesOnSuccess: true
        )
        _ = await task.value

        #expect(FileManager.default.fileExists(atPath: mic.path) == true)
    }

    @Test func failedConversion_keepsSources_andSurfacesError() async throws {
        struct Boom: Error {}
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "conv-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mic = tmp.appending(path: "mic.caf")
        let dest = tmp.appending(path: "combined.flac")
        try Data("mic".utf8).write(to: mic)

        let service = RecordingConversionService { _, _, _ in
            throw Boom()
        }

        let task = await service.startConversion(
            folderName: "rec", mic: mic, system: nil,
            destination: dest, keepSourcesOnSuccess: false
        )
        let outcome = await task.value

        switch outcome.result {
        case .success:
            Issue.record("expected failure")
        case .failure(let err):
            #expect(err.message.isEmpty == false)
        }
        // Sources MUST survive a failed conversion — we keep them as fallback evidence.
        #expect(FileManager.default.fileExists(atPath: mic.path) == true)
        #expect(FileManager.default.fileExists(atPath: dest.path) == false)
        #expect(await service.isConverting(folderName: "rec") == false)
    }
}
```

- [ ] **Step 2: Run the tests to verify they all fail with "no such type"**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingConversionServiceTests`
Expected: FAIL with "cannot find 'RecordingConversionService' in scope" (the type doesn't exist yet).

- [ ] **Step 3: Commit the failing tests**

```bash
git add Packages/AudioPipeline/Tests/RecordingCoreTests/RecordingConversionServiceTests.swift
git commit -m "test: add failing tests for RecordingConversionService"
```

---

## Task 3: Implement `RecordingConversionService`

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/RecordingConversionService.swift`

- [ ] **Step 1: Write the service**

```swift
import Foundation
import os

// Orchestrates background CAF→FLAC conversion for stopped recordings.
//
// Lives in the package so the app target only wires UI/state. Owns a
// dictionary of in-flight conversion tasks keyed by folder name so multiple
// concurrent conversions don't clobber each other — the original PR's
// `pendingConversion` single-slot design lost B's task reference when A's
// completion handler cleared it unconditionally.
//
// The combine operation is injected at init so tests can supply a controllable
// fake. The default uses `CombinedFLACExporter.combine`.
public actor RecordingConversionService {

    public struct Outcome: Sendable {
        public let folderName: String
        public let result: Result<Void, ConversionFailure>
    }

    public struct ConversionFailure: Error, Sendable {
        public let message: String
    }

    public typealias Combine = @Sendable (
        _ mic: URL, _ system: URL?, _ destination: URL
    ) async throws -> Void

    private let combine: Combine
    private var inflight: [String: Task<Outcome, Never>] = [:]

    public init(combine: @escaping Combine = { mic, system, destination in
        try await CombinedFLACExporter.combine(mic: mic, system: system, to: destination)
    }) {
        self.combine = combine
    }

    public func startConversion(
        folderName: String,
        mic: URL,
        system: URL?,
        destination: URL,
        keepSourcesOnSuccess: Bool
    ) -> Task<Outcome, Never> {
        let combine = self.combine
        let task = Task<Outcome, Never> { [weak self] in
            let outcome: Outcome
            do {
                try await combine(mic, system, destination)
                if !keepSourcesOnSuccess {
                    try? FileManager.default.removeItem(at: mic)
                    if let system {
                        try? FileManager.default.removeItem(at: system)
                    }
                }
                outcome = Outcome(folderName: folderName, result: .success(()))
            } catch {
                Self.log.error("conversion failed for \(folderName, privacy: .public): \(String(describing: error), privacy: .public)")
                outcome = Outcome(
                    folderName: folderName,
                    result: .failure(ConversionFailure(message: error.localizedDescription))
                )
            }
            await self?.clear(folderName: folderName)
            return outcome
        }
        inflight[folderName] = task
        return task
    }

    public func waitForConversion(folderName: String) async {
        guard let task = inflight[folderName] else { return }
        _ = await task.value
    }

    public func isConverting(folderName: String) -> Bool {
        inflight[folderName] != nil
    }

    private func clear(folderName: String) {
        inflight[folderName] = nil
    }

    private static let log = Logger(
        subsystem: "work.miklos.audio-pipeline",
        category: "conversion-service"
    )
}
```

- [ ] **Step 2: Run the tests and verify all pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingConversionServiceTests`
Expected: PASS on all six tests in the suite.

- [ ] **Step 3: Run the whole RecordingCore test target to confirm no regressions**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingCoreTests`
Expected: PASS. Existing tests (`RecorderStateMachineTests`, `CombinedFLACExporterTests`, etc.) untouched.

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/RecordingConversionService.swift
git commit -m "feat(core): add RecordingConversionService actor with per-folder tracking"
```

---

## Task 4: Make `RecordingsLibrary.refresh()` async (failing tests first)

**Files:**
- Modify: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingsLibraryTests.swift`

The existing test file calls `library.refresh()` synchronously. Migrate it to `await library.refresh()` and make each test `async`. We do this *before* changing the source so the suite fails on the signature mismatch, then passes once the source matches.

- [ ] **Step 1: Update the test file to await async refresh/delete**

Replace the contents of `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingsLibraryTests.swift` with:

```swift
import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingsLibraryTests {
    @Test func refresh_listsValidFoldersSortedNewestFirst() async throws {
        try await withTempDirectoryAsync { baseURL in
            let older = makeMetadata(
                folderName: "older",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let newer = makeMetadata(
                folderName: "newer",
                startedAt: Date(timeIntervalSince1970: 1_700_100_000)
            )
            try makeRecordingFolderOnDisk(in: baseURL, name: "older", metadata: older)
            try makeRecordingFolderOnDisk(in: baseURL, name: "newer", metadata: newer)

            let library = RecordingsLibrary { baseURL }
            await library.refresh()

            #expect(library.recordings.map(\.name) == ["newer", "older"])
        }
    }

    @Test func refresh_skipsNonDirectoryEntries() async throws {
        try await withTempDirectoryAsync { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "valid", metadata: makeMetadata(folderName: "valid"))
            try Data("stray".utf8).write(
                to: baseURL.appending(path: "stray.txt", directoryHint: .notDirectory)
            )

            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            #expect(library.recordings.map(\.name) == ["valid"])
        }
    }

    @Test func refresh_skipsFoldersWithoutMetaJSON() async throws {
        try await withTempDirectoryAsync { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "valid", metadata: makeMetadata(folderName: "valid"))
            try makeRecordingFolderOnDisk(in: baseURL, name: "no-meta", metadata: nil, tracks: ["mic.caf": 10])

            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            #expect(library.recordings.map(\.name) == ["valid"])
        }
    }

    @Test func refresh_missingBaseDirectory_yieldsEmptyList() async {
        let baseURL = URL(
            filePath: "/tmp/audio-pipeline-tests-does-not-exist-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let library = RecordingsLibrary { baseURL }
        await library.refresh()
        #expect(library.recordings.isEmpty)
    }

    @Test func delete_keepsLibraryConsistentWithDisk() async throws {
        try await withTempDirectoryAsync { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "doomed", metadata: makeMetadata(folderName: "doomed"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let target = try #require(library.recordings.first { $0.name == "doomed" })

            await library.delete(target)

            let folderStillOnDisk = FileManager.default.fileExists(atPath: target.folderURL.path)
            let folderInList = library.recordings.contains { $0.name == "doomed" }
            #expect(folderStillOnDisk == folderInList)
        }
    }

    @Test(.enabled(if: Self.trashAvailable))
    func delete_movesFolderToTrash() async throws {
        try await withTempDirectoryAsync { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "doomed-real", metadata: makeMetadata(folderName: "doomed-real"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let target = try #require(library.recordings.first { $0.name == "doomed-real" })

            await library.delete(target)

            #expect(library.recordings.contains { $0.name == "doomed-real" } == false)
            #expect(FileManager.default.fileExists(atPath: target.folderURL.path) == false)
        }
    }

    nonisolated(unsafe) static let trashAvailable: Bool = {
        let probe = FileManager.default.temporaryDirectory.appending(
            path: "trash-probe-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        do {
            try FileManager.default.trashItem(at: probe, resultingItemURL: nil)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return false
        }
    }()
}

// Async variant of the existing `withTempDirectory(_:)` Support helper.
// We add this rather than retrofit the sync helper because the body now
// needs to await library APIs.
@MainActor
private func withTempDirectoryAsync(
    _ body: (URL) async throws -> Void
) async throws {
    let baseURL = FileManager.default.temporaryDirectory.appending(
        path: "audio-pipeline-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseURL) }
    try await body(baseURL)
}
```

Note: `makeMetadata`, `makeRecordingFolderOnDisk` and the sync `withTempDirectory` are existing helpers in `Packages/AudioPipeline/Tests/RecordingStorageTests/Support/` — leave them alone; the new `withTempDirectoryAsync` is just an async sibling for this file.

- [ ] **Step 2: Run the tests to verify failure on signature mismatch**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingsLibraryTests`
Expected: COMPILE FAIL — "no 'async' operations occur within 'await' expression" or similar — because `refresh()` and `delete(_:)` are still synchronous in the source.

- [ ] **Step 3: Commit the failing test migration**

```bash
git add Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingsLibraryTests.swift
git commit -m "test: migrate RecordingsLibraryTests to async refresh/delete"
```

---

## Task 5: Make `RecordingsLibrary.refresh()` and `delete()` async with off-main scan

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift`

Move the directory enumeration + per-folder JSON decode off the main actor. The mutation of `recordings` stays on `@MainActor`.

- [ ] **Step 1: Update the source**

Replace the body of `RecordingsLibrary` with:

```swift
import Foundation
import Observation

// The model behind the Recordings window. Scans the recordings directory and
// parses each recording's meta.json into a list sorted newest-first.
//
// `refresh()` dispatches the scan to a background task so a library with many
// recordings doesn't stall the main thread on `Data(contentsOf:)` +
// JSONDecoder() per folder. The final assignment to `recordings` is back on
// `@MainActor`.
@MainActor
@Observable
public final class RecordingsLibrary {
    public private(set) var recordings: [RecordingItem] = []

    @ObservationIgnored private let baseURLProvider: @MainActor () -> URL

    public init(baseURLProvider: @MainActor @escaping () -> URL) {
        self.baseURLProvider = baseURLProvider
    }

    public func refresh() async {
        let baseURL = baseURLProvider()
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scan(baseURL: baseURL)
        }.value
        recordings = scanned
    }

    // Deletes a recording by moving its whole folder to the Trash (recoverable).
    public func delete(_ item: RecordingItem) async {
        try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        await refresh()
    }

    private nonisolated static func scan(baseURL: URL) -> [RecordingItem] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { RecordingItem(folderURL: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

public struct RecordingItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let folderURL: URL
    public let startedAt: Date
    public let duration: Double?
    public let sizeBytes: Int64
    public let formatSummary: String

    public nonisolated init?(folderURL: URL) {
        let metadataURL = folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: metadataURL),
              let meta = try? Self.decoder.decode(RecordingMetadata.self, from: data) else {
            return nil
        }

        id = meta.folderName
        name = meta.folderName
        self.folderURL = folderURL
        startedAt = meta.startedAt
        duration = meta.durationSeconds

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var total: Int64 = 0
        var hasCAF = false
        var hasFLAC = false
        for file in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            switch file.pathExtension.lowercased() {
            case "caf":  hasCAF = true
            case "flac": hasFLAC = true
            default:     break
            }
        }
        sizeBytes = total
        formatSummary = [hasCAF ? "caf" : nil, hasFLAC ? "flac" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")
    }

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

Note: `RecordingItem` gains a `Sendable` conformance because it now crosses a Task boundary. All stored fields are value types of `Sendable` (`String`, `URL`, `Date`, `Double?`, `Int64`) so the conformance is mechanical.

- [ ] **Step 2: Run the storage tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingsLibraryTests`
Expected: PASS on all six tests.

- [ ] **Step 3: Run the whole storage target to confirm no regression in sibling tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingStorageTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift
git commit -m "perf(storage): scan recordings off the main actor in RecordingsLibrary.refresh"
```

---

## Task 6: Wire `RecordingConversionService` into `AppCoordinator`

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

This task removes the inline `Task.detached` + `pendingConversion` slot + `FileManager.removeItem` from the app target. The `AppCoordinator` becomes a pure wiring layer: it owns the service, asks it to convert, awaits the outcome, and updates UI/state.

- [ ] **Step 1: Replace the `pendingConversion` storage and remove the nested struct**

At `audio-pipeline/AppCoordinator.swift:52-59`, change:

```swift
    private var machine = RecorderStateMachine()
    private var session: RecordingSession?
    private var pendingConversion: PendingConversion?

    private struct PendingConversion {
        let folderName: String
        let task: Task<Void, Error>
    }
```

To:

```swift
    private var machine = RecorderStateMachine()
    private var session: RecordingSession?
    private let conversionService = RecordingConversionService()
```

- [ ] **Step 2: Rewrite the post-stop conversion block in `stopRecording()`**

At `audio-pipeline/AppCoordinator.swift:133-189`, replace the body of `stopRecording()` with:

```swift
    func stopRecording() async {
        guard machine.stop() == .stopSession, let active = session else { return }

        let folder = active.folder
        let result = await active.stop()
        session = nil

        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")

        let stoppedAction = machine.sessionStopped(folderURL: folder.url)
        guard case .convertOutput = stoppedAction else { return }

        // meta.json was written synchronously inside active.stop(); the row is
        // now visible to library.refresh().
        await library.refresh()
        recordingActivity = "Converting recording…"

        let keepCAF = settings.keepOriginalCAF
        let micURL = folder.micURL
        let systemURL: URL? = FileManager.default.fileExists(atPath: folder.systemURL.path)
            ? folder.systemURL : nil
        let combinedURL = folder.combinedURL
        let folderName = folder.name

        let conversionTask = await conversionService.startConversion(
            folderName: folderName,
            mic: micURL,
            system: systemURL,
            destination: combinedURL,
            keepSourcesOnSuccess: keepCAF
        )

        Task { @MainActor in
            let outcome = await conversionTask.value
            let result: Result<Void, Error>
            switch outcome.result {
            case .success:
                result = .success(())
            case .failure(let failure):
                result = .failure(failure)
            }
            _ = self.machine.conversionFinished(result)
            await self.library.refresh()
            switch outcome.result {
            case .success:
                await self.flashRecordingActivity("Recording ready")
            case .failure(let failure):
                await self.flashRecordingActivity("Conversion failed: \(failure.message)")
            }
        }
    }
```

Note: this preserves the spec's behaviour — synchronous-ish row appearance (the `await library.refresh()` only suspends; it doesn't block the main thread because the scan now runs on a detached task), conversion footer, post-conversion library refresh, and success/failure flash messages.

- [ ] **Step 3: Update `runJob` to go through the service**

At `audio-pipeline/AppCoordinator.swift:205-216` replace the `pendingConversion` wait block:

```swift
        // If conversion for this recording is still in flight, wait for it
        // before checking combined.flac. Failure is fine here — the existence
        // check below will return the canonical .combinedFlacMissing.
        if let pending = pendingConversion, pending.folderName == recordingName {
            jobActivity = "Waiting for '\(recordingName)' to finish converting…"
            _ = try? await pending.task.value
        }
```

With:

```swift
        // If conversion for this recording is still in flight, wait for it
        // before checking combined.flac. Failure is fine here — the existence
        // check below will return the canonical .combinedFlacMissing.
        if await conversionService.isConverting(folderName: recordingName) {
            jobActivity = "Waiting for '\(recordingName)' to finish converting…"
            await conversionService.waitForConversion(folderName: recordingName)
        }
```

- [ ] **Step 4: Build the app target via the xcode-build skill / external script**

Inside the Claude Code sandbox, `xcodebuild` is blocked; use the helper described in `CLAUDE.md`. From a normal terminal:

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build 2>&1 | tee /tmp/audio-pipeline-build.log | tail -40
```

Expected: `BUILD SUCCEEDED`. If anywhere in the file an `import` of `RecordingConversionService`'s type is missing, the existing `import RecordingCore` at the top already covers it.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "refactor(coordinator): route conversion through RecordingConversionService"
```

---

## Task 7: Update `RecordingsView` for async refresh/delete

**Files:**
- Modify: `audio-pipeline/UI/RecordingsView.swift`

Three call sites need to become `Task { ... }` wrappers. SwiftUI's `.onAppear` doesn't take an async closure, but `.task` does and is the idiomatic replacement.

- [ ] **Step 1: Update the `.onAppear` to `.task`**

At `audio-pipeline/UI/RecordingsView.swift:21`, change:

```swift
            .onAppear { library.refresh() }
```

To:

```swift
            .task { await library.refresh() }
```

- [ ] **Step 2: Wrap the delete-button action**

At `audio-pipeline/UI/RecordingsView.swift:60`, change:

```swift
                Button("Move to Trash", role: .destructive) { library.delete(item) }
```

To:

```swift
                Button("Move to Trash", role: .destructive) {
                    Task { await library.delete(item) }
                }
```

- [ ] **Step 3: Wrap the toolbar refresh button action**

At `audio-pipeline/UI/RecordingsView.swift:65-71`, change:

```swift
            .toolbar {
                Button {
                    library.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
```

To:

```swift
            .toolbar {
                Button {
                    Task { await library.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
```

- [ ] **Step 4: Build**

From a normal terminal:

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build 2>&1 | tee /tmp/audio-pipeline-build.log | tail -40
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/UI/RecordingsView.swift
git commit -m "refactor(ui): await async library.refresh/delete in RecordingsView"
```

---

## Task 8: Full test pass + manual smoke verification

**Files:** none modified — verification only.

- [ ] **Step 1: Run all SPM tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS on every suite. Pay attention to:
- `RecordingConversionServiceTests` — the new suite from Tasks 2-3.
- `RecordingsLibraryTests` — the migrated async suite from Tasks 4-5.
- `RecorderStateMachineTests` — should be unchanged; verifies we didn't break the lifecycle.

- [ ] **Step 2: Run the app-hosted XCTest target**

From a normal terminal (the helper script is documented in `CLAUDE.md`):

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test 2>&1 | tee /tmp/audio-pipeline-tests.log | tail -60
```

Expected: PASS.

- [ ] **Step 3: Manual smoke — single recording**

Launch the app (Xcode ⌘R or `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`). Then:
1. Start a recording. Stop after ~3 seconds.
2. **Expected:** Recordings panel row appears immediately with `format = caf`. Footer shows "Converting recording…". UI stays responsive (drag the window, scroll the table — no hitches).
3. Within a couple of seconds: footer flashes "Recording ready", `format` updates to `caf + flac` (or `flac` only if `keepOriginalCAF` is off).

- [ ] **Step 4: Manual smoke — overlapping conversions (the load-bearing bug)**

This is the regression test for the original reviewer finding.

1. Start a long recording (≥ 30 s of audio to make conversion non-trivial).
2. Stop it. Immediately (within ~1 s) start a second recording. Record briefly, then stop.
3. While the second conversion is presumably in flight, trigger a job on the **first** recording (Run Job → any job).
4. **Expected:** the job either runs against the existing `combined.flac` (if the first conversion already completed) or waits ("Waiting for '<first>' to finish converting…") and then runs. It must NOT immediately fail with `combinedFlacMissing`.

This exercises `service.isConverting(folderName:)` + `service.waitForConversion(folderName:)` on the *non-most-recent* folder — the exact case the single-slot design broke.

- [ ] **Step 5: Manual smoke — job-during-conversion on the same recording**

1. Start a long recording, stop it.
2. Immediately right-click the new row → Run Job → any job, while the footer still shows "Converting…".
3. **Expected:** job footer reads "Waiting for '<name>' to finish converting…", then "Running '<job>' on '<name>'…", then a success or failure flash. No `combinedFlacMissing` error if the conversion succeeded.

- [ ] **Step 6: Manual smoke — many recordings (refresh perf)**

Optional but instructive. Drop ~50 valid recording folders into the recordings directory (you can copy an existing one and edit `meta.json`'s `folderName`). Open the Recordings window. Expected: the table populates without a visible UI freeze; if there's a beat of delay it should be a single frame, not a long stall, because the scan is on `Task.detached(.userInitiated)`.

- [ ] **Step 7: Commit any verification artefacts (none expected) and push**

If everything passes, no further code commits are needed. Push the branch and request re-review:

```bash
git push
gh pr comment 2 --body "Addressed the three reviewer findings:

- **Pending conversion clobber**: extracted into a new \`RecordingConversionService\` actor with a \`[String: Task]\` keyed by folder name. Tested via a new \`RecordingConversionServiceTests\` suite that exercises overlapping conversions.
- **Architecture violation (rules 772232 / 772234)**: conversion task creation, completion tracking, and CAF cleanup now live inside the package; \`AppCoordinator\` only spawns the service call and updates UI/state.
- **Main-thread refresh**: \`RecordingsLibrary.refresh()\` is now async and scans on \`Task.detached(.userInitiated)\`; \`delete()\` is async too. Existing storage tests migrated.

Plan: \`docs/superpowers/plans/2026-05-28-non-blocking-recording-finish-review-fixes.md\`."
```

---

## Self-review

**Spec coverage:**
- Finding 1 (pending-conversion clobber): Tasks 2-3 (service with dictionary), Task 6 (coordinator wiring), Task 8 step 4 (manual regression test). ✓
- Finding 2 (architecture violation, rules 772232 / 772234): Task 3 (service in `Packages/AudioPipeline/Sources/RecordingCore/`), Task 6 (coordinator no longer touches `FileManager.removeItem` or owns the task). ✓
- Finding 3 (main-thread refresh): Tasks 4-5 (async refresh + off-main scan), Task 7 (UI call-site updates), Task 8 step 6 (manual perf check). ✓

**Placeholder scan:** no "TBD", "TODO", "implement later", "fill in details", or vague "add error handling" entries. Each step has the full code or full command it needs.

**Type consistency:**
- `RecordingConversionService.startConversion(folderName:mic:system:destination:keepSourcesOnSuccess:)` — same signature in Task 2 (tests), Task 3 (impl), Task 6 (coordinator caller).
- `Outcome { folderName, result: Result<Void, ConversionFailure> }` and `ConversionFailure { message: String }` — same shape in tests, impl, and the coordinator's `flashRecordingActivity("Conversion failed: \(failure.message)")` line.
- `RecordingsLibrary.refresh() async` and `delete(_:) async` — consistent in source (Task 5), tests (Task 4), and call sites (Tasks 6, 7).
- `keepSourcesOnSuccess` parameter name reused everywhere instead of the older `keepOriginalCAF` (which remains the AppSettings key).
