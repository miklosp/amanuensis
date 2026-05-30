# Providers / Jobs Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split today's monolithic `Job` into a `Provider` (endpoint + key, shape pinned via preset) and a `Job` (model, prompt, params, output), with a new "Providers" sidebar entry, no migration of the old `jobs.json`, and broken-Job UI when a Provider is missing.

**Architecture:** New `Provider` value type + `ProvidersStore` JSON file at `Application Support/<bundleID>/providers.json`, both mirroring today's `Job`/`JobsStore`. `Job` keeps its identity + per-run fields and gains `providerID: UUID?`. The runner and handler take an extra `Provider` parameter; AppCoordinator resolves the Provider before invoking the runner and throws `JobRunError.providerMissing` if not found. Pre-release wipe: a `jobs.json` that fails to decode under the new schema is deleted on first launch.

**Tech Stack:** Swift 6.2, SwiftUI on macOS 26.3, Swift Testing, JSON persistence in Application Support, `@MainActor @Observable` stores.

**Spec:** `docs/superpowers/specs/2026-05-30-providers-jobs-split-design.md`

---

## File Map

**Create (SPM target `AudioPipelineJobs`):**
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/Provider.swift`
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/ProvidersStore.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProviderTests.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProvidersStoreTests.swift`

**Create (app target):**
- `audio-pipeline/UI/Providers/ProviderEditorView.swift`
- `audio-pipeline/UI/Providers/ProvidersView.swift`

**Modify:**
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift`
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift`
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift`
- `audio-pipeline/AppCoordinator.swift`
- `audio-pipeline/UI/MainWindowView.swift`
- `audio-pipeline/UI/Jobs/JobEditorView.swift`
- `audio-pipeline/UI/Jobs/JobsView.swift`

**Test command (SPM, runs in this sandbox):**
```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline
```

**Test command (app target, must run outside sandbox via the xcode-build daemon — task notes call out when this is needed):**
```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test
```

---

## Task 1: Add `Provider` value type + tests

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Provider.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProviderTests.swift`

This is a pure addition; nothing depends on `Provider` yet, so SPM tests and the app target both stay green after this task.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct ProviderCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let provider = Provider(
            id: id,
            name: "OpenAI (chat audio)",
            presetID: "openai-chat-audio",
            baseURL: "https://api.openai.com",
            apiKeyRef: KeychainRef(account: "openai-personal")
        )
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(Provider.self, from: data)
        #expect(decoded == provider)
    }

    @Test func id_isStable_acrossEdits() {
        let id = UUID()
        var p = Provider(id: id, name: "a", presetID: "x",
                         baseURL: "", apiKeyRef: KeychainRef(account: ""))
        p.name = "b"
        #expect(p.id == id)
    }
}

@Suite struct ProviderMakeDraft {
    @Test func usesFirstPresetWhenAvailable() {
        let preset = Preset(
            id: "openai-compat-chat",
            displayName: "OpenAI Compatible",
            shape: .chatCompletionsAudio,
            baseURL: "https://api.example/v1",
            suggestedModels: ["gpt-4o-audio"],
            defaults: [:]
        )
        let presets = PresetsStore(presets: [preset])

        let draft = Provider.makeDraft(presets: presets)

        #expect(draft.name == "Untitled provider")
        #expect(draft.presetID == "openai-compat-chat")
        #expect(draft.baseURL == "https://api.example/v1")
        #expect(draft.apiKeyRef.account == "")
    }

    @Test func fallsBackToEmptyDefaultsWhenNoPresets() {
        let presets = PresetsStore(presets: [])

        let draft = Provider.makeDraft(presets: presets)

        #expect(draft.name == "Untitled provider")
        #expect(draft.presetID == "")
        #expect(draft.baseURL == "")
        #expect(draft.apiKeyRef.account == "")
    }

    @Test func assignsDistinctIDsPerCall() {
        let presets = PresetsStore(presets: [])
        let a = Provider.makeDraft(presets: presets)
        let b = Provider.makeDraft(presets: presets)
        #expect(a.id != b.id)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ProviderCodable
```
Expected: build error — `cannot find 'Provider' in scope` (file doesn't exist yet).

- [ ] **Step 3: Create `Provider.swift`**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/Provider.swift`:

```swift
import Foundation

// User-defined API endpoint + credentials. Many Jobs reference one Provider.
// Shape (the wire-level protocol) is pinned by the Provider's preset, so
// switching presets is a deliberate decision the user makes on the Provider,
// not implicitly when editing a Job.
public struct Provider: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var presetID: String
    public var baseURL: String
    public var apiKeyRef: KeychainRef

    public init(id: UUID = UUID(), name: String, presetID: String,
                baseURL: String, apiKeyRef: KeychainRef) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
    }

    public static func makeDraft(presets: PresetsStore) -> Provider {
        let first = presets.all.first
        return Provider(
            name: "Untitled provider",
            presetID: first?.id ?? "",
            baseURL: first?.baseURL ?? "",
            apiKeyRef: KeychainRef(account: "")
        )
    }
}
```

- [ ] **Step 4: Run the tests; they should pass**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ProviderCodable
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ProviderMakeDraft
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Provider.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProviderTests.swift
git -c commit.gpgsign=false commit -m "feat(jobs): add Provider value type and makeDraft"
```

---

## Task 2: Add `ProvidersStore` + tests

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ProvidersStore.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProvidersStoreTests.swift`

Mirror of `JobsStore` — `@MainActor @Observable`, JSON-on-disk, same `standard(bundleID:)` constructor pattern. Still additive; no existing code consumes it.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProvidersStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func tempFile() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("providers-\(UUID().uuidString).json")
}

private func makeProvider(name: String = "demo") -> Provider {
    Provider(name: name, presetID: "openai-compat-chat",
             baseURL: "http://localhost:4444/openai",
             apiKeyRef: KeychainRef(account: "bifrost"))
}

@MainActor
@Suite struct ProvidersStoreBehavior {
    @Test func emptyStore_hasNoProviders() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        #expect(store.providers.isEmpty)
    }

    @Test func upsert_addsNewProvider() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        let p = makeProvider()
        store.upsert(p)
        #expect(store.providers == [p])
    }

    @Test func upsert_replacesExistingByID() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        var p = makeProvider()
        store.upsert(p)
        p.name = "renamed"
        store.upsert(p)
        #expect(store.providers.count == 1)
        #expect(store.providers.first?.name == "renamed")
    }

    @Test func delete_removesByID() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        let p = makeProvider()
        store.upsert(p)
        store.delete(id: p.id)
        #expect(store.providers.isEmpty)
    }

    @Test func provider_byID_returnsMatchOrNil() throws {
        let store = try ProvidersStore(fileURL: tempFile())
        let p = makeProvider()
        store.upsert(p)
        #expect(store.provider(id: p.id) == p)
        #expect(store.provider(id: UUID()) == nil)
    }

    @Test func persistsAcrossInstances() throws {
        let url = tempFile()
        let first = try ProvidersStore(fileURL: url)
        first.upsert(makeProvider(name: "persisted"))
        let second = try ProvidersStore(fileURL: url)
        #expect(second.providers.first?.name == "persisted")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ProvidersStoreBehavior
```
Expected: build error — `cannot find 'ProvidersStore' in scope`.

- [ ] **Step 3: Create `ProvidersStore.swift`**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/ProvidersStore.swift`:

```swift
import Foundation
import Observation

// Persistent list of Providers. JSON-on-disk in Application Support. Observable
// so the Providers UI re-renders on CRUD.
@MainActor
@Observable
public final class ProvidersStore {
    public private(set) var providers: [Provider] = []

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try load()
    }

    // Constructs a ProvidersStore at the standard app location:
    //   Application Support/<bundleID>/providers.json
    public static func standard(bundleID: String) throws -> ProvidersStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try ProvidersStore(fileURL: dir.appendingPathComponent("providers.json"))
    }

    public func upsert(_ provider: Provider) {
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[idx] = provider
        } else {
            providers.append(provider)
        }
        save()
    }

    public func delete(id: UUID) {
        providers.removeAll { $0.id == id }
        save()
    }

    public func provider(id: UUID) -> Provider? {
        providers.first { $0.id == id }
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        providers = try JSONDecoder().decode([Provider].self, from: data)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(providers)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal for the in-memory store. The app
            // composition root logs from the catch around ProvidersStore.standard.
        }
    }
}
```

- [ ] **Step 4: Run tests; expect green**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ProvidersStoreBehavior
```
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/ProvidersStore.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ProvidersStoreTests.swift
git -c commit.gpgsign=false commit -m "feat(jobs): add ProvidersStore"
```

---

## Task 3: Wire `ProvidersStore` into `AppCoordinator`

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift` (around line 48 — alongside `jobs`)

Wires the new store with the same fallback pattern as `jobs`. Nothing else changes; the UI still doesn't reference it.

- [ ] **Step 1: Add the property + init wiring**

In `audio-pipeline/AppCoordinator.swift`, add a `providers` property next to `jobs`. After this edit the relevant section should read:

```swift
    let settings: AppSettings
    let library: RecordingsLibrary
    let keychain: KeychainStore
    let presets: PresetsStore
    let jobs: JobsStore
    let providers: ProvidersStore
```

And in `init()`, after the `jobs` init block, add:

```swift
        do {
            self.providers = try ProvidersStore.standard(bundleID: "work.miklos.audio-pipeline")
        } catch {
            Self.log.error("failed to load providers: \(String(describing: error), privacy: .public)")
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("providers-fallback.json")
            self.providers = (try? ProvidersStore(fileURL: tmp)) ?? {
                preconditionFailure("could not initialise ProvidersStore even at temp path")
            }()
        }
```

- [ ] **Step 2: Build the SPM target (no behaviour test yet)**

```bash
swift build --package-path Packages/AudioPipeline
```
Expected: clean build.

- [ ] **Step 3: Build the app target outside the sandbox**

Tell the user: "I need an xcodebuild run via the daemon to confirm the app still compiles." The daemon path:

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: build succeeds. App still launches and behaves identically (providers store is unused so far).

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git -c commit.gpgsign=false commit -m "feat(jobs): wire ProvidersStore into AppCoordinator"
```

---

## Task 4: Reshape `Job` (breaking change — atomic with consumers)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift`

`Job` loses `presetID`/`baseURL`/`apiKeyRef`, gains `providerID: UUID?`. Handler and Runner take an extra `Provider` parameter. All five test files get fixture rewrites in lockstep. The app target's `JobEditorView` will break — fixed in Task 7. Between this task and Task 7, only the SPM tests build/pass; the app target won't build.

- [ ] **Step 1: Rewrite `JobTests.swift`**

Replace the entire contents of `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift` with:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let providerID = UUID()
        let job = Job(
            id: id,
            name: "Swedish lesson transcription",
            providerID: providerID,
            model: "gemini-flash",
            fields: ["prompt": "Transcribe...", "temperature": "0.2"],
            outputExt: "txt",
            outputFolderPath: "/Users/x/Documents/transcripts"
        )
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded == job)
        #expect(decoded.outputFolderPath == "/Users/x/Documents/transcripts")
        #expect(decoded.providerID == providerID)
    }

    @Test func roundTrip_preservesNilProviderID() throws {
        let job = Job(name: "draft", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded.providerID == nil)
    }

    @Test func id_isStable_acrossEdits() {
        let id = UUID()
        var job = Job(id: id, name: "a", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        job.name = "b"
        #expect(job.id == id)
    }

    @Test func outputFolderPath_defaultsToNil() {
        let job = Job(name: "n", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        #expect(job.outputFolderPath == nil)
    }
}
```

- [ ] **Step 2: Rewrite `JobMakeDraftTests.swift`**

Replace the entire contents with:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobMakeDraft {
    @Test func draftHasNoProvider() {
        let draft = Job.makeDraft()
        #expect(draft.providerID == nil)
        #expect(draft.name == "Untitled")
        #expect(draft.model == "")
        #expect(draft.fields == [:])
        #expect(draft.outputExt == "txt")
        #expect(draft.outputFolderPath == nil)
    }

    @Test func assignsDistinctIDsPerCall() {
        let a = Job.makeDraft()
        let b = Job.makeDraft()
        #expect(a.id != b.id)
    }
}
```

- [ ] **Step 3: Rewrite `Job.swift`**

Replace the entire contents of `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift` with:

```swift
import Foundation

// User-saved configuration for one audio→text run. References a Provider for
// endpoint/credentials/shape; carries only the per-run fields (model, prompt
// and shape-specific params, output location). Stored as JSON on disk via
// JobsStore.
public struct Job: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String                 // user label, e.g. "Swedish lesson"
    public var providerID: UUID?            // nil = unset (draft or broken)
    public var model: String                // free text; provider.preset.suggestedModels is autocomplete
    public var fields: [String: String]     // shape-specific values, validated against provider's preset shape
    public var outputExt: String            // "txt", "json", "srt"
    public var outputFolderPath: String?    // nil = next to recording; set = absolute path to folder

    public init(id: UUID = UUID(), name: String, providerID: UUID?,
                model: String, fields: [String: String], outputExt: String,
                outputFolderPath: String? = nil) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.model = model
        self.fields = fields
        self.outputExt = outputExt
        self.outputFolderPath = outputFolderPath
    }

    public static func makeDraft() -> Job {
        Job(name: "Untitled", providerID: nil, model: "",
            fields: [:], outputExt: "txt")
    }
}
```

- [ ] **Step 4: Rewrite `JobsStoreTests.swift` fixtures**

Replace the `makeJob` helper and the `JobsStoreBehavior` suite in `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func tempFile() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    return dir.appendingPathComponent("jobs-\(UUID().uuidString).json")
}

private func makeJob(name: String = "demo", providerID: UUID = UUID()) -> Job {
    Job(name: name, providerID: providerID, model: "gemini-flash",
        fields: ["prompt": "Transcribe this."], outputExt: "txt")
}

@MainActor
@Suite struct JobsStoreBehavior {
    @Test func emptyStore_hasNoJobs() throws {
        let store = try JobsStore(fileURL: tempFile())
        #expect(store.jobs.isEmpty)
    }

    @Test func upsert_addsNewJob() throws {
        let store = try JobsStore(fileURL: tempFile())
        let job = makeJob()
        store.upsert(job)
        #expect(store.jobs == [job])
    }

    @Test func upsert_replacesExistingByID() throws {
        let store = try JobsStore(fileURL: tempFile())
        var job = makeJob()
        store.upsert(job)
        job.name = "renamed"
        store.upsert(job)
        #expect(store.jobs.count == 1)
        #expect(store.jobs.first?.name == "renamed")
    }

    @Test func delete_removesByID() throws {
        let store = try JobsStore(fileURL: tempFile())
        let job = makeJob()
        store.upsert(job)
        store.delete(id: job.id)
        #expect(store.jobs.isEmpty)
    }

    @Test func persistsAcrossInstances() throws {
        let url = tempFile()
        let first = try JobsStore(fileURL: url)
        first.upsert(makeJob(name: "persisted"))
        let second = try JobsStore(fileURL: url)
        #expect(second.jobs.first?.name == "persisted")
    }
}
```

- [ ] **Step 5: Update `ChatCompletionsAudioHandler.swift`**

Two edits:

(a) Change `buildRequest` to take a `provider: Provider` and read `provider.baseURL`. Replace the function signature and the `trimmedBase` derivation:

```swift
    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard let prompt = job.fields["prompt"], !prompt.isEmpty else {
            throw BuildError.missingPrompt
        }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let endpoint = URL(string: trimmedBase + "/v1/chat/completions") else {
            throw BuildError.invalidBaseURL
        }
```

(b) Change `send` and the protocol to thread `provider`:

```swift
    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let request = try buildRequest(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey)
        // … rest unchanged …
    }
```

```swift
public protocol ChatCompletionsAudioSending: Sendable {
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String
}

public struct DefaultChatCompletionsAudioSender: ChatCompletionsAudioSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await ChatCompletionsAudioHandler.send(job: job, provider: provider,
                                                   audioURL: audioURL, apiKey: apiKey)
    }
}
```

- [ ] **Step 6: Update `JobRunner.swift`**

Replace the file with:

```swift
import Foundation

// Glue: fetch API key → call handler → write result file next to recording.
// Single-shape for the MVP slice; later shapes get their own sender protocol
// or a dispatch table inside the runner.
public struct JobRunner: Sendable {
    private let keychain: any KeychainProviding
    private let handler: any ChatCompletionsAudioSending

    public init(
        keychain: any KeychainProviding,
        handler: any ChatCompletionsAudioSending = DefaultChatCompletionsAudioSender()
    ) {
        self.keychain = keychain
        self.handler = handler
    }

    @discardableResult
    public func run(job: Job, provider: Provider, audioURL: URL) async throws -> URL {
        let key = try await keychain.get(account: provider.apiKeyRef.account)
        let text = try await handler.send(job: job, provider: provider,
                                          audioURL: audioURL, apiKey: key)
        let folder: URL
        if let path = job.outputFolderPath, !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = audioURL.deletingLastPathComponent()
        }
        let outURL = Self.uniqueOutputURL(in: folder, jobName: job.name, ext: job.outputExt)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: outURL, options: .atomic)
        return outURL
    }

    static func uniqueOutputURL(in folder: URL, jobName: String, ext: String) -> URL {
        let sanitised = jobName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = "combined-\(sanitised)"
        let candidate = folder.appendingPathComponent("\(base).\(ext)")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        var n = 1
        while true {
            let alt = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: alt.path) { return alt }
            n += 1
        }
    }
}
```

- [ ] **Step 7: Rewrite `JobRunnerTests.swift`**

Replace the entire contents with:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private actor FakeKeychain: KeychainProviding {
    let key: String
    init(key: String) { self.key = key }
    func get(account: String) async throws -> String { key }
}

private actor FakeHandler: ChatCompletionsAudioSending {
    private(set) var lastJob: Job?
    private(set) var lastProvider: Provider?
    private(set) var lastAudio: URL?
    private(set) var lastKey: String?
    let result: Result<String, Error>
    init(result: Result<String, Error>) { self.result = result }
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        lastJob = job; lastProvider = provider; lastAudio = audioURL; lastKey = apiKey
        return try result.get()
    }
}

private func makeProvider() -> Provider {
    Provider(name: "p", presetID: "openai-compat-chat",
             baseURL: "http://x", apiKeyRef: KeychainRef(account: "acc"))
}

private func makeJob(providerID: UUID, outputExt: String = "txt") -> Job {
    Job(name: "demo", providerID: providerID, model: "m",
        fields: ["prompt": "p"], outputExt: outputExt)
}

private func makeAudio() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("combined.flac")
    try Data([0x01, 0x02]).write(to: url)
    return url
}

@Suite struct JobRunnerBehavior {
    @Test func run_writesOutputFile_nextToRecording() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let keychain = FakeKeychain(key: "sk-x")
        let handler = FakeHandler(result: .success("transcribed text"))
        let runner = JobRunner(keychain: keychain, handler: handler)
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, audioURL: audio)
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "transcribed text")
        #expect(outURL.lastPathComponent == "combined-demo.txt")
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }

    @Test func run_appendsConflictSuffix_whenOutputFileExists() async throws {
        let audio = try makeAudio()
        let folder = audio.deletingLastPathComponent()
        let existing = folder.appendingPathComponent("combined-demo.txt")
        try Data("prior".utf8).write(to: existing)

        let provider = makeProvider()
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("new"))
        )
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-demo (1).txt")
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "new")
    }

    @Test func run_sanitisesSlashesAndColonsInJobName() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("x"))
        )
        var job = makeJob(providerID: provider.id)
        job.name = "Folder/With:Bad chars"
        let outURL = try await runner.run(job: job, provider: provider, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-Folder-With-Bad chars.txt")
    }

    @Test func run_fetchesKeyForProvidersAccount() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-real")
        let handler = FakeHandler(result: .success("ok"))
        let runner = JobRunner(keychain: keychain, handler: handler)
        let provider = makeProvider()
        _ = try await runner.run(job: makeJob(providerID: provider.id),
                                 provider: provider, audioURL: audio)
        #expect(await handler.lastKey == "sk-real")
        #expect(await handler.lastProvider?.id == provider.id)
        #expect(await handler.lastAudio == audio)
    }

    @Test func run_propagatesHandlerErrors() async throws {
        struct Boom: Error {}
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handler: FakeHandler(result: .failure(Boom())))
        do {
            _ = try await runner.run(job: makeJob(providerID: provider.id),
                                     provider: provider, audioURL: audio)
            Issue.record("expected throw")
        } catch is Boom {
            // expected
        }
    }

    @Test func run_writesToCustomFolder_whenOutputFolderPathSet() async throws {
        let audio = try makeAudio()
        let customFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider()
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("hello"))
        )
        var job = makeJob(providerID: provider.id)
        job.outputFolderPath = customFolder.path
        let outURL = try await runner.run(job: job, provider: provider, audioURL: audio)
        #expect(outURL.deletingLastPathComponent().path == customFolder.path)
        #expect(outURL.lastPathComponent == "combined-demo.txt")
    }

    @Test func run_writesNextToAudio_whenOutputFolderPathNil() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("hi"))
        )
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, audioURL: audio)
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }
}
```

- [ ] **Step 8: Rewrite `ChatCompletionsAudioHandlerTests.swift` fixtures**

Replace the `makeJob` helper and update the suite. The helper now constructs a Provider too:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "http://localhost:4444/openai") -> Provider {
    Provider(name: "p", presetID: "openai-compat-chat",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "bifrost"))
}

private func makeJob(prompt: String, model: String = "gemini-flash",
                     audioFormat: String? = nil,
                     temperature: String? = nil) -> Job {
    var fields: [String: String] = ["prompt": prompt]
    if let audioFormat { fields["audio_format"] = audioFormat }
    if let temperature { fields["temperature"] = temperature }
    return Job(name: "t", providerID: UUID(), model: model,
               fields: fields, outputExt: "txt")
}

private func writeAudio(_ bytes: [UInt8], ext: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).\(ext)")
    try Data(bytes).write(to: url)
    return url
}
```

Then update every `buildRequest`/`send` call site inside the two suites to pass `provider:`. For example the `buildsPOST_toChatCompletionsPath` test becomes:

```swift
    @Test func buildsPOST_toChatCompletionsPath() throws {
        let job = makeJob(prompt: "Hello")
        let provider = makeProvider()
        let audio = try writeAudio([0x01, 0x02], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://localhost:4444/openai/v1/chat/completions")
    }
```

Apply the same pattern to all the other tests in `ChatCompletionsAudioRequest` and `ChatCompletionsAudioResponse` — every call to `buildRequest`/`send` gains a `provider:` argument built via `makeProvider()`. For `trailingSlashInBaseURL_isHandled`, pass the trailing-slash URL to the provider, not the job:

```swift
    @Test func trailingSlashInBaseURL_isHandled() throws {
        let job = makeJob(prompt: "p")
        let provider = makeProvider(baseURL: "http://example.com/")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "k")
        #expect(req.url?.absoluteString == "http://example.com/v1/chat/completions")
    }
```

- [ ] **Step 9: Run all SPM tests**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline
```
Expected: every test in the AudioPipelineJobs suite passes. (`RecordingCore` and `RecordingStorage` suites are unaffected.)

- [ ] **Step 10: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift
git -c commit.gpgsign=false commit -m "feat(jobs): reshape Job around Provider reference

Job loses presetID/baseURL/apiKeyRef and gains providerID: UUID?.
Handler and Runner take a Provider argument; tests reflect the
new contract. App target temporarily uncompiles until JobEditorView
is rewritten in the next task."
```

---

## Task 5: Rewrite `AppCoordinator.runJob` to resolve Provider + wipe stale jobs.json

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

Resolves the Provider before invoking the runner; adds `JobRunError.providerMissing`; deletes `jobs.json` if it fails to decode under the new schema so a stale file can't keep us stuck.

The app target still won't build until Task 7 (JobEditorView is broken), but this task lands the coordinator-side changes.

- [ ] **Step 1: Add `providerMissing` to `JobRunError`**

In `audio-pipeline/AppCoordinator.swift`:

```swift
    enum JobRunError: Error {
        case combinedFlacMissing
        case providerMissing
    }
```

- [ ] **Step 2: Update `runJob(_:on:)` to resolve Provider**

Replace the body of `runJob` (around line 194) with:

```swift
    @discardableResult
    func runJob(_ job: Job, on recordingFolder: URL) async -> Result<URL, Error> {
        let recordingName = recordingFolder.lastPathComponent

        guard let providerID = job.providerID,
              let provider = providers.provider(id: providerID) else {
            await self.flashActivity("Failed: '\(job.name)' — provider missing")
            return .failure(JobRunError.providerMissing)
        }

        if await conversionService.isConverting(folderName: recordingName) {
            withAnimation { jobActivity = "Waiting for '\(recordingName)' to finish converting…" }
            await conversionService.waitForConversion(folderName: recordingName)
        }

        withAnimation { jobActivity = "Running '\(job.name)' on '\(recordingName)'…" }

        let target = recordingFolder.appendingPathComponent("combined.flac")
        guard FileManager.default.fileExists(atPath: target.path) else {
            await self.flashActivity("Failed: '\(job.name)' — combined.flac missing")
            return .failure(JobRunError.combinedFlacMissing)
        }
        let runner = JobRunner(keychain: keychain)
        do {
            let out = try await runner.run(job: job, provider: provider, audioURL: target)
            await self.flashActivity("Done: '\(job.name)' → \(out.lastPathComponent)")
            return .success(out)
        } catch {
            Self.log.error("job '\(job.name, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
            await self.flashActivity("Failed: '\(job.name)' — \(error.localizedDescription)")
            return .failure(error)
        }
    }
```

- [ ] **Step 3: Wipe stale `jobs.json` on decode failure**

Replace the existing `jobs` init block (around line 68) with:

```swift
        do {
            self.jobs = try JobsStore.standard(bundleID: "work.miklos.audio-pipeline")
        } catch {
            Self.log.error("failed to load jobs (likely stale schema): \(String(describing: error), privacy: .public)")
            // Pre-release wipe: drop a stale jobs.json so the next launch starts clean.
            let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            if let url = support?
                .appendingPathComponent("work.miklos.audio-pipeline", isDirectory: true)
                .appendingPathComponent("jobs.json") {
                try? FileManager.default.removeItem(at: url)
            }
            // Try once more from the standard location; fall back to a temp file if even that fails.
            self.jobs = (try? JobsStore.standard(bundleID: "work.miklos.audio-pipeline")) ?? {
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("jobs-fallback.json")
                return (try? JobsStore(fileURL: tmp)) ?? {
                    preconditionFailure("could not initialise JobsStore even at temp path")
                }()
            }()
        }
```

- [ ] **Step 4: Confirm SPM still builds**

```bash
swift build --package-path Packages/AudioPipeline
```
Expected: clean build. (The app target still won't compile because JobEditorView is broken — that's expected and fixed next.)

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git -c commit.gpgsign=false commit -m "feat(jobs): resolve Provider in runJob; wipe stale jobs.json"
```

---

## Task 6: Add `ProviderEditorView` and `ProvidersView`

**Files:**
- Create: `audio-pipeline/UI/Providers/ProviderEditorView.swift`
- Create: `audio-pipeline/UI/Providers/ProvidersView.swift`

Two new view files. The `Providers/` subfolder is auto-picked-up by the synchronized group; no pbxproj edit needed. App target still won't compile (JobEditorView next), so we just write the files and defer build verification to Task 7.

- [ ] **Step 1: Create `ProviderEditorView.swift`**

```swift
import AppKit
import AudioPipelineJobs
import SwiftUI

struct ProviderEditorView: View {
    @State private var name: String
    @State private var presetID: String
    @State private var baseURL: String
    @State private var apiKeyAccount: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let keychain: KeychainStore
    private let onSave: (Provider) -> Void

    init(initial: Provider, presets: PresetsStore, keychain: KeychainStore,
         onSave: @escaping (Provider) -> Void) {
        self.presets = presets
        self.keychain = keychain
        self.onSave = onSave

        self.initialID = initial.id
        _name = State(initialValue: initial.name)
        _presetID = State(initialValue: initial.presetID)
        _baseURL = State(initialValue: initial.baseURL)
        _apiKeyAccount = State(initialValue: initial.apiKeyRef.account)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Picker("Preset", selection: $presetID) {
                        ForEach(presets.all) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    .onChange(of: presetID) { _, newID in
                        guard let p = presets.preset(id: newID) else { return }
                        baseURL = p.baseURL
                    }
                    TextField("Base URL", text: $baseURL)
                    KeychainAccountPicker(account: $apiKeyAccount, keychain: keychain)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
            .padding(12)
        }
    }

    private var canSave: Bool {
        !name.isEmpty && !presetID.isEmpty && !apiKeyAccount.isEmpty
    }

    private func save() {
        let provider = Provider(id: initialID, name: name, presetID: presetID,
                                baseURL: baseURL,
                                apiKeyRef: KeychainRef(account: apiKeyAccount))
        onSave(provider)
    }
}
```

- [ ] **Step 2: Create `ProvidersView.swift`**

```swift
import AudioPipelineJobs
import SwiftUI

struct ProvidersView: View {
    let presets: PresetsStore
    @Bindable var providers: ProvidersStore
    let keychain: KeychainStore

    @State private var selection: Provider.ID?

    private var sortedProviders: [Provider] {
        providers.providers.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        HSplitView {
            List(sortedProviders, selection: $selection) { provider in
                Text(provider.name).tag(Optional(provider.id))
            }
            .frame(minWidth: 200, idealWidth: 240)

            ProvidersDetailPane(
                provider: sortedProviders.first(where: { $0.id == selection }),
                presets: presets,
                keychain: keychain,
                onSave: { providers.upsert($0) }
            )
            .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addProvider()
                } label: {
                    Label("New Provider", systemImage: "plus")
                }
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sortedProviders.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if let id = selection, sortedProviders.contains(where: { $0.id == id }) {
            return
        }
        selection = sortedProviders.first?.id
    }

    private func addProvider() {
        let draft = Provider.makeDraft(presets: presets)
        providers.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        providers.delete(id: id)
        selection = nil
    }
}

private struct ProvidersDetailPane: View {
    let provider: Provider?
    let presets: PresetsStore
    let keychain: KeychainStore
    let onSave: (Provider) -> Void

    var body: some View {
        if let provider {
            ProviderEditorView(initial: provider,
                               presets: presets,
                               keychain: keychain,
                               onSave: onSave)
                .id(provider.id)
        } else {
            ContentUnavailableView("Select a provider", systemImage: "key")
        }
    }
}
```

- [ ] **Step 3: Commit (no build yet — app target completes in Task 7)**

```bash
git add audio-pipeline/UI/Providers/ProviderEditorView.swift \
        audio-pipeline/UI/Providers/ProvidersView.swift
git -c commit.gpgsign=false commit -m "feat(jobs): add ProviderEditorView and ProvidersView"
```

---

## Task 7: Rewrite `JobEditorView` around the Provider picker

**Files:**
- Modify: `audio-pipeline/UI/Jobs/JobEditorView.swift`

This task gets the app target compiling again. New editor: Name, Provider picker, Model (with provider-derived suggestions), Parameters (driven by the provider's preset shape), Output extension, Custom output folder. Provider-switching applies the same-shape / different-shape rules from the spec.

- [ ] **Step 1: Replace `JobEditorView.swift`**

Replace the entire contents of `audio-pipeline/UI/Jobs/JobEditorView.swift` with:

```swift
import AppKit
import AudioPipelineJobs
import SwiftUI

struct JobEditorView: View {
    @State private var name: String
    @State private var providerID: UUID?
    @State private var model: String
    @State private var fields: [String: String]
    @State private var outputExt: String
    @State private var customOutputFolder: Bool
    @State private var outputFolderPath: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let providers: ProvidersStore
    private let onSave: (Job) -> Void

    init(initial: Job, presets: PresetsStore, providers: ProvidersStore,
         onSave: @escaping (Job) -> Void) {
        self.presets = presets
        self.providers = providers
        self.onSave = onSave

        self.initialID = initial.id
        _name = State(initialValue: initial.name)
        _providerID = State(initialValue: initial.providerID)
        _model = State(initialValue: initial.model)
        _fields = State(initialValue: initial.fields)
        _outputExt = State(initialValue: initial.outputExt)
        let startingFolder = initial.outputFolderPath ?? ""
        _customOutputFolder = State(initialValue: !startingFolder.isEmpty)
        _outputFolderPath = State(initialValue: startingFolder)
    }

    private var provider: Provider? {
        providerID.flatMap { providers.provider(id: $0) }
    }

    private var preset: Preset? {
        provider.flatMap { presets.preset(id: $0.presetID) }
    }

    private var shape: JobShape? { preset?.shape }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Picker("Provider", selection: $providerID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(providers.providers.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .onChange(of: providerID) { oldID, newID in
                        let oldShape = oldID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }?.shape
                        let newShape = newID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }?.shape
                        if oldShape != newShape {
                            // Shape changed — clear model and reset fields to new preset's defaults.
                            model = ""
                            let newDefaults = newID
                                .flatMap { providers.provider(id: $0) }
                                .flatMap { presets.preset(id: $0.presetID) }?.defaults ?? [:]
                            fields = newDefaults
                        }
                    }
                    HStack {
                        TextField("Model", text: $model)
                        if let suggestions = preset?.suggestedModels, !suggestions.isEmpty {
                            Menu("Suggested") {
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { model = s }
                                }
                            }
                            .frame(width: 110)
                        }
                    }
                    TextField("Output extension", text: $outputExt)
                    Toggle(isOn: $customOutputFolder) {
                        Text("Custom output folder")
                    }
                    if customOutputFolder {
                        HStack {
                            Text(outputFolderPath.isEmpty ? "—" : outputFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: chooseOutputFolder)
                        }
                    }
                }

                if let shape {
                    Section("Parameters") {
                        JobFieldFormView(shape: shape, values: $fields)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
            .padding(12)
        }
    }

    private var canSave: Bool {
        let folderOK = !customOutputFolder || !outputFolderPath.isEmpty
        return !name.isEmpty && providerID != nil && !model.isEmpty && folderOK
    }

    private func save() {
        let job = Job(
            id: initialID, name: name, providerID: providerID,
            model: model, fields: fields, outputExt: outputExt,
            outputFolderPath: customOutputFolder && !outputFolderPath.isEmpty
                ? outputFolderPath : nil
        )
        onSave(job)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let url = URL(string: outputFolderPath), FileManager.default.fileExists(atPath: url.path) {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }
}
```

- [ ] **Step 2: Update `JobsView.swift` to thread `providers` into the editor**

In `audio-pipeline/UI/Jobs/JobsView.swift`, change the view's stored properties and the detail pane to take `providers`. Replace the existing top-of-file struct + detail pane with:

```swift
import AudioPipelineJobs
import SwiftUI

struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    @Bindable var providers: ProvidersStore
    let keychain: KeychainStore

    @State private var selection: Job.ID?

    private var sortedJobs: [Job] {
        jobs.jobs.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        HSplitView {
            List(sortedJobs, selection: $selection) { job in
                Text(job.name).tag(Optional(job.id))
            }
            .frame(minWidth: 200, idealWidth: 240)

            JobsDetailPane(
                job: sortedJobs.first(where: { $0.id == selection }),
                presets: presets,
                providers: providers,
                onSave: { jobs.upsert($0) }
            )
            .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .disabled(providers.providers.isEmpty)
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sortedJobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if let id = selection, sortedJobs.contains(where: { $0.id == id }) {
            return
        }
        selection = sortedJobs.first?.id
    }

    private func addJob() {
        guard !providers.providers.isEmpty else { return }
        let draft = Job.makeDraft()
        jobs.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        jobs.delete(id: id)
        selection = nil
    }
}

private struct JobsDetailPane: View {
    let job: Job?
    let presets: PresetsStore
    let providers: ProvidersStore
    let onSave: (Job) -> Void

    var body: some View {
        if let job {
            JobEditorView(initial: job,
                          presets: presets,
                          providers: providers,
                          onSave: onSave)
                .id(job.id)
        } else {
            ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
        }
    }
}
```

- [ ] **Step 3: Build the app target outside the sandbox**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```
Expected: clean build. (Compile error in `MainWindowView` is expected here — the call site to `JobsView` still passes the old `keychain:` arg and lacks `providers:`. Fix it as part of this step's `JobsView` edit by also updating MainWindowView. Apply the next sub-step before re-running the build.)

- [ ] **Step 4: Update `MainWindowView` call site for `JobsView`**

In `audio-pipeline/UI/MainWindowView.swift`, change the `.jobs` branch (around line 30) to:

```swift
            case .jobs:
                JobsView(presets: coordinator.presets,
                         jobs: coordinator.jobs,
                         providers: coordinator.providers,
                         keychain: coordinator.keychain)
                    .navigationTitle("Jobs")
```

(`keychain` is no longer used by `JobsView` directly — once you drop the parameter, remove it from the call site too. The version above keeps the surface minimal but you can also drop the unused param. If you drop it, also remove the `keychain: KeychainStore` line from `JobsView`'s stored properties.)

For DRY: drop the unused `keychain` parameter. Final `JobsView` top:

```swift
struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    @Bindable var providers: ProvidersStore
    …
```

And the call site:

```swift
            case .jobs:
                JobsView(presets: coordinator.presets,
                         jobs: coordinator.jobs,
                         providers: coordinator.providers)
                    .navigationTitle("Jobs")
```

- [ ] **Step 5: Re-build the app target**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```
Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add audio-pipeline/UI/Jobs/JobEditorView.swift \
        audio-pipeline/UI/Jobs/JobsView.swift \
        audio-pipeline/UI/MainWindowView.swift
git -c commit.gpgsign=false commit -m "feat(jobs): rewrite JobEditorView around Provider picker"
```

---

## Task 8: Add the Providers sidebar entry

**Files:**
- Modify: `audio-pipeline/UI/MainWindowView.swift`

Adds `.providers` to `SidebarDestination`, a sidebar `Label`, and the detail route.

- [ ] **Step 1: Add `.providers` to `SidebarDestination`**

At the bottom of `audio-pipeline/UI/MainWindowView.swift`:

```swift
enum SidebarDestination: Hashable {
    case recordings, jobs, providers
}
```

- [ ] **Step 2: Add the sidebar `Label`**

Inside the `List(selection:)` in `MainWindowView.body`, under `Section("Library")`:

```swift
                Section("Library") {
                    Label("Recordings", systemImage: "waveform")
                        .tag(SidebarDestination.recordings)
                    Label("Jobs", systemImage: "wand.and.stars")
                        .tag(SidebarDestination.jobs)
                    Label("Providers", systemImage: "key")
                        .tag(SidebarDestination.providers)
                }
```

- [ ] **Step 3: Add the detail route**

In the `switch selection` block:

```swift
            case .providers:
                ProvidersView(presets: coordinator.presets,
                              providers: coordinator.providers,
                              keychain: coordinator.keychain)
                    .navigationTitle("Providers")
```

- [ ] **Step 4: Build + launch the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```
Expected: clean build.

Then ask the user to launch the app from Xcode (⌘R), confirm the sidebar shows Recordings / Jobs / Providers, and confirm clicking "Providers" shows the list (empty) + the `+ New Provider` toolbar button works.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/UI/MainWindowView.swift
git -c commit.gpgsign=false commit -m "feat(jobs): add Providers sidebar entry"
```

---

## Task 9: Empty-providers state in Jobs + broken-Job UI

**Files:**
- Modify: `audio-pipeline/UI/Jobs/JobsView.swift`
- Modify: `audio-pipeline/UI/Jobs/JobEditorView.swift`

Adds:
- `ContentUnavailableView("No providers configured", …)` with a "Go to Providers" button when the providers list is empty.
- A toast / inline message "Add a provider first." when the user tries to act on an empty providers list (the disabled `+ New Job` button already prevents the click, so this surfaces only via the empty state).
- A warning badge on Jobs whose `providerID` doesn't resolve.
- A "Provider missing" repair pane in `JobEditorView` when the current job's provider doesn't resolve.

The "Go to Providers" button needs a way to change the parent sidebar selection — we add a `@Binding<SidebarDestination>` to `JobsView` and thread it from `MainWindowView`.

- [ ] **Step 1: Thread sidebar selection into `JobsView`**

In `audio-pipeline/UI/MainWindowView.swift`, change the `.jobs` branch to pass a binding:

```swift
            case .jobs:
                JobsView(presets: coordinator.presets,
                         jobs: coordinator.jobs,
                         providers: coordinator.providers,
                         sidebarSelection: $selection)
                    .navigationTitle("Jobs")
```

- [ ] **Step 2: Add the binding + empty state + broken-row badge to `JobsView`**

Update `audio-pipeline/UI/Jobs/JobsView.swift`. Replace the top-level struct (preserving the rest as-is from Task 7) with:

```swift
struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    @Bindable var providers: ProvidersStore
    @Binding var sidebarSelection: SidebarDestination

    @State private var selection: Job.ID?

    private var sortedJobs: [Job] {
        jobs.jobs.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func isBroken(_ job: Job) -> Bool {
        guard let id = job.providerID else { return true }
        return providers.provider(id: id) == nil
    }

    var body: some View {
        Group {
            if providers.providers.isEmpty {
                ContentUnavailableView {
                    Label("No providers configured", systemImage: "key")
                } description: {
                    Text("Add a provider first.")
                } actions: {
                    Button("Go to Providers") {
                        sidebarSelection = .providers
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                HSplitView {
                    List(sortedJobs, selection: $selection) { job in
                        HStack(spacing: 6) {
                            if isBroken(job) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Text(job.name)
                        }
                        .tag(Optional(job.id))
                    }
                    .frame(minWidth: 200, idealWidth: 240)

                    JobsDetailPane(
                        job: sortedJobs.first(where: { $0.id == selection }),
                        presets: presets,
                        providers: providers,
                        onSave: { jobs.upsert($0) }
                    )
                    .frame(minWidth: 420)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .disabled(providers.providers.isEmpty)
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sortedJobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if let id = selection, sortedJobs.contains(where: { $0.id == id }) {
            return
        }
        selection = sortedJobs.first?.id
    }

    private func addJob() {
        guard !providers.providers.isEmpty else { return }
        let draft = Job.makeDraft()
        jobs.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        jobs.delete(id: id)
        selection = nil
    }
}
```

- [ ] **Step 3: Replace `JobEditorView.swift` with the broken-Job repair pane wired in**

Replace the entire contents of `audio-pipeline/UI/Jobs/JobEditorView.swift` with:

```swift
import AppKit
import AudioPipelineJobs
import SwiftUI

struct JobEditorView: View {
    @State private var name: String
    @State private var providerID: UUID?
    @State private var model: String
    @State private var fields: [String: String]
    @State private var outputExt: String
    @State private var customOutputFolder: Bool
    @State private var outputFolderPath: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let providers: ProvidersStore
    private let onSave: (Job) -> Void

    init(initial: Job, presets: PresetsStore, providers: ProvidersStore,
         onSave: @escaping (Job) -> Void) {
        self.presets = presets
        self.providers = providers
        self.onSave = onSave

        self.initialID = initial.id
        _name = State(initialValue: initial.name)
        _providerID = State(initialValue: initial.providerID)
        _model = State(initialValue: initial.model)
        _fields = State(initialValue: initial.fields)
        _outputExt = State(initialValue: initial.outputExt)
        let startingFolder = initial.outputFolderPath ?? ""
        _customOutputFolder = State(initialValue: !startingFolder.isEmpty)
        _outputFolderPath = State(initialValue: startingFolder)
    }

    private var provider: Provider? {
        providerID.flatMap { providers.provider(id: $0) }
    }

    private var preset: Preset? {
        provider.flatMap { presets.preset(id: $0.presetID) }
    }

    private var shape: JobShape? { preset?.shape }

    var body: some View {
        if providerID == nil || provider == nil {
            repairPane
        } else {
            editorForm
        }
    }

    @ViewBuilder
    private var repairPane: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Provider missing", systemImage: "key.slash")
            } description: {
                Text("Pick a provider to repair this job. Switching shapes resets prompt/parameters.")
            }
            Picker("Provider", selection: $providerID) {
                Text("Select…").tag(UUID?.none)
                ForEach(providers.providers.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .onChange(of: providerID) { _, newID in
                let newPreset = newID
                    .flatMap { providers.provider(id: $0) }
                    .flatMap { presets.preset(id: $0.presetID) }
                model = ""
                fields = newPreset?.defaults ?? [:]
            }
            .frame(maxWidth: 360)
            Button("Save repair") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .buttonStyle(.glassProminent)
        }
        .padding(24)
    }

    @ViewBuilder
    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Picker("Provider", selection: $providerID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(providers.providers.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .onChange(of: providerID) { oldID, newID in
                        let oldShape = oldID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }?.shape
                        let newShape = newID
                            .flatMap { providers.provider(id: $0) }
                            .flatMap { presets.preset(id: $0.presetID) }?.shape
                        if oldShape != newShape {
                            model = ""
                            let newDefaults = newID
                                .flatMap { providers.provider(id: $0) }
                                .flatMap { presets.preset(id: $0.presetID) }?.defaults ?? [:]
                            fields = newDefaults
                        }
                    }
                    HStack {
                        TextField("Model", text: $model)
                        if let suggestions = preset?.suggestedModels, !suggestions.isEmpty {
                            Menu("Suggested") {
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { model = s }
                                }
                            }
                            .frame(width: 110)
                        }
                    }
                    TextField("Output extension", text: $outputExt)
                    Toggle(isOn: $customOutputFolder) {
                        Text("Custom output folder")
                    }
                    if customOutputFolder {
                        HStack {
                            Text(outputFolderPath.isEmpty ? "—" : outputFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: chooseOutputFolder)
                        }
                    }
                }

                if let shape {
                    Section("Parameters") {
                        JobFieldFormView(shape: shape, values: $fields)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
            .padding(12)
        }
    }

    private var canSave: Bool {
        let folderOK = !customOutputFolder || !outputFolderPath.isEmpty
        return !name.isEmpty && providerID != nil && !model.isEmpty && folderOK
    }

    private func save() {
        let job = Job(
            id: initialID, name: name, providerID: providerID,
            model: model, fields: fields, outputExt: outputExt,
            outputFolderPath: customOutputFolder && !outputFolderPath.isEmpty
                ? outputFolderPath : nil
        )
        onSave(job)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let url = URL(string: outputFolderPath), FileManager.default.fileExists(atPath: url.path) {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }
}
```

- [ ] **Step 4: Build + manual smoke**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```
Expected: clean build.

Ask the user to manually verify:
- Launch the app; sidebar shows Recordings / Jobs / Providers.
- Click Jobs: shows "No providers configured" with a "Go to Providers" button. Clicking it switches the sidebar.
- Click Providers, add one (OpenAI Whisper). Switch back to Jobs.
- `+ New Job` is now enabled. Click it; editor shows Name, Provider, Model, Parameters, Output extension, Custom output folder. Pick the provider; fields populate from preset defaults.
- Set name + model + provider + (optional) custom folder. Save. Job appears in the list.
- Switch to Providers and delete the provider. Switch back to Jobs: the job row now shows the warning badge; clicking it opens the "Provider missing" repair pane.
- Add a new provider with a different shape. Pick it in the repair pane; fields reset.

- [ ] **Step 5: Run all SPM tests once more**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline
```
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add audio-pipeline/UI/Jobs/JobsView.swift \
        audio-pipeline/UI/Jobs/JobEditorView.swift \
        audio-pipeline/UI/MainWindowView.swift
git -c commit.gpgsign=false commit -m "feat(jobs): empty-providers and broken-job UI"
```

---

## Task 10: End-to-end smoke + final polish

**Files:** (none changed unless smoke surfaces issues)

- [ ] **Step 1: Run the full SPM suite**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline
```
Expected: all green across `AudioPipelineJobsTests`, `AppSettingsTests`, `RecordingCoreTests`, `RecordingStorageTests`.

- [ ] **Step 2: Run the app-hosted XCTest suite**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test
```
Expected: all green. (Existing `MainWindowViewTests` and `RecordingFormattersTests` are untouched.)

- [ ] **Step 3: Real end-to-end smoke**

Ask the user to:
1. Open the app in Xcode (⌘R).
2. Create a Provider pointing at a real endpoint with a working API key.
3. Record a short clip (mic-only is fine).
4. After conversion finishes, run the Job from the recording row.
5. Confirm the output file appears next to the recording (or in the custom folder if set).

If anything fails, debug-and-fix loop here before considering the task done.

- [ ] **Step 4: Confirm branch state is clean**

```bash
git status
git log --oneline main..HEAD
```
Expected: working tree clean; commit list shows the 9 feature commits in order.

---

## Self-Review Notes (filled in during plan-write)

- **Spec coverage:** every `Provider` field, every `Job` field rename, the runner signature change, the wipe-on-decode-failure, the empty-providers state, the broken-Job badge, the repair pane, the toolbar disabled state, and both test surfaces are accounted for.
- **`Job.makeDraft` signature drop:** spec says `Provider.makeDraft(presets:)` exists; `Job.makeDraft()` no longer needs presets because nothing pre-fills from preset (provider is unset). Tests updated accordingly.
- **Same-shape preservation on Provider switch:** lives only in `JobEditorView.onChange(of: providerID)` — when the editor is showing a normally-resolvable job. The broken-Job repair path always resets (the old provider is gone, so we can't compare shapes).
- **Sidebar binding:** added in Task 9 specifically for the "Go to Providers" button. The Recordings view doesn't need it; only `JobsView` does.
