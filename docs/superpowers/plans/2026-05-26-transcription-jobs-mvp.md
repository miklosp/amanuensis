# Transcription Jobs MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user define audio→text Jobs (per-provider configs) in Settings, store API keys in Keychain, and run any Job against any recording from a right-click menu. First shipped handler covers the OpenAI-compatible chat-completions-with-`input_audio` shape (Bifrost, OpenRouter, OpenAI gpt-4o-audio).

**Architecture:** New SPM module `AudioPipelineJobs` houses the data model (`JobShape`, `Preset`, `Job`, `FieldSpec`), persistence (`JobsStore` JSON-on-disk, `PresetsStore` from bundled resources), Keychain wrapper (`KeychainStore` actor), one HTTP handler (`ChatCompletionsAudioHandler`), and the orchestrator (`JobRunner`). The app target adds a Settings tab for Jobs management and a Recordings context menu. The other three shapes (transcription multipart, Gemini native, ElevenLabs) are stubbed in `JobShape` but their handlers are deferred to follow-up slices.

**Tech Stack:** Swift 6.2 (`.defaultIsolation(MainActor.self)`), Swift Testing (`@Suite` / `@Test` / `#expect`), `@Observable` for stores, `actor` for Keychain, `URLSession` + `URLProtocol`-stubbed tests for HTTP, SwiftUI for UI.

**Reference design conversation:** Synthesised in this session 2026-05-26.

---

## File Structure

### Files created

| Path | Purpose |
|---|---|
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift` | Enum of the 4 endpoint shapes |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift` | UI form metadata, `JobShape.fields` extension |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/Preset.swift` | Shipped template; `Codable` |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainRef.swift` | Account-name reference to a Keychain entry |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift` | User-saved job; `Codable` |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainStore.swift` | Nonisolated `actor` wrapping `Security.framework` |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/PresetsStore.swift` | Loads `presets.json` from module bundle |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobsStore.swift` | `@Observable`, JSON-on-disk in Application Support |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift` | HTTP handler for the chat-completions-with-`input_audio` shape |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift` | Orchestrates handler + output write |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json` | Bundled preset library |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift` | Shape enum / `FieldSpec` invariants |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetTests.swift` | Codable round-trip |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift` | Codable round-trip |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/KeychainStoreTests.swift` | Real Keychain under a per-run service ID |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift` | All 9 presets load, lookup by id |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift` | CRUD + JSON persistence round-trip |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift` | Request building, response parsing, error paths via `URLProtocol` stub |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift` | End-to-end with a fake handler |
| `audio-pipeline/UI/Jobs/JobsSettingsPanel.swift` | Settings tab: list of Jobs |
| `audio-pipeline/UI/Jobs/JobEditorView.swift` | Sheet: add/edit a Job |
| `audio-pipeline/UI/Jobs/JobFieldFormView.swift` | Auto-generated form from `JobShape.fields` |
| `audio-pipeline/UI/Jobs/KeychainAccountPicker.swift` | Picks/creates an API-key Keychain entry |

### Files modified

| Path | Change |
|---|---|
| `Packages/AudioPipeline/Package.swift` | Add `AudioPipelineJobs` library product + test target with bundled resources |
| `audio-pipeline/AppCoordinator.swift` | Construct `KeychainStore`, `PresetsStore`, `JobsStore`; expose to UI |
| `audio-pipeline/UI/SettingsView.swift` | Convert single Form to `TabView` with "Recording" + "Jobs" tabs |
| `audio-pipeline/UI/RecordingsView.swift` | Add context menu: "Run Job ▸ …" submenu |
| `audio-pipeline.xcodeproj/project.pbxproj` | Add `AudioPipelineJobs` library to app target (via `scripts/run-setup-spm-package.sh AudioPipelineJobs`) |
| `CLAUDE.md` | Mention the new module in the "Tests" section |

### Conventions reused from existing modules

- Public API only on types the app or other modules consume.
- `@Observable final class` for stores; MainActor by default per module `swiftSettings`.
- `KeychainStore` is `actor`-isolated (nonisolated module — see below).
- Swift Testing throughout (`@Suite`, `@Test`, `#expect`).

---

## Module isolation choice

`AudioPipelineJobs` has UI-facing observable stores (MainActor-natural) AND a network/Keychain layer (off-main-thread-natural). Following the existing `RecordingCore` precedent (nonisolated settings + explicit `@MainActor` on what needs it), we set this module to **nonisolated** swiftSettings and add `@MainActor` to the observable stores and SwiftUI-facing helpers. This avoids accidentally pulling Keychain calls onto MainActor and matches the audio module's pattern.

---

## Task 1: Add `AudioPipelineJobs` SPM target

**Files:**
- Modify: `Packages/AudioPipeline/Package.swift`
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/` (directory)
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/` (directory)
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SmokeTests.swift`

- [ ] **Step 1: Create the source and resource directories**

```bash
mkdir -p Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources
mkdir -p Packages/AudioPipeline/Tests/AudioPipelineJobsTests
```

- [ ] **Step 2: Add the library product + targets to `Package.swift`**

Edit `Packages/AudioPipeline/Package.swift`. After the existing `RecordingCore` library entry, add a new product; after the `RecordingCore` target entry, add a new target with resources; after the existing test targets, add a new test target.

```swift
// In `products: [...]`, append:
.library(name: "AudioPipelineJobs", targets: ["AudioPipelineJobs"]),

// In `targets: [...]`, append:
.target(
    name: "AudioPipelineJobs",
    resources: [.process("Resources")],
    swiftSettings: nonisolatedSettings
),
.testTarget(
    name: "AudioPipelineJobsTests",
    dependencies: ["AudioPipelineJobs"],
    swiftSettings: nonisolatedSettings
),
```

- [ ] **Step 3: Write a smoke test that proves the target wires up**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SmokeTests.swift`:

```swift
import Testing
@testable import AudioPipelineJobs

@Suite struct AudioPipelineJobsSmoke {
    @Test func module_imports() {
        // Compiling and linking is the assertion.
        #expect(true)
    }
}
```

- [ ] **Step 4: Verify `swift test` discovers the new target**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter AudioPipelineJobsSmoke`
Expected: 1 test, passes.

- [ ] **Step 5: Wire the library into the app target via the project script**

Run: `scripts/run-setup-spm-package.sh AudioPipelineJobs`
Expected: script reports idempotent add; `git status` shows `project.pbxproj` modified.

- [ ] **Step 6: Build the app to confirm linkage**

Run via the xcode-build skill / external terminal:
`xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/AudioPipeline/Package.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests \
        audio-pipeline.xcodeproj/project.pbxproj
git commit -m "feat(jobs): scaffold AudioPipelineJobs SPM target"
```

---

## Task 2: `JobShape` enum

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobShapeBehavior {
    @Test func rawValues_areStable() {
        #expect(JobShape.chatCompletionsAudio.rawValue == "chatCompletionsAudio")
        #expect(JobShape.transcriptionMultipart.rawValue == "transcriptionMultipart")
        #expect(JobShape.elevenLabsScribe.rawValue == "elevenLabsScribe")
        #expect(JobShape.geminiGenerateContent.rawValue == "geminiGenerateContent")
    }

    @Test func codable_roundTrip() throws {
        for shape in JobShape.allCases {
            let data = try JSONEncoder().encode(shape)
            let decoded = try JSONDecoder().decode(JobShape.self, from: data)
            #expect(decoded == shape)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobShapeBehavior`
Expected: FAIL — `JobShape` undefined.

- [ ] **Step 3: Implement `JobShape`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift`:

```swift
import Foundation

// The wire-level endpoint shape a Job dispatches to. One per code-level handler.
public enum JobShape: String, Codable, CaseIterable, Hashable, Sendable {
    case chatCompletionsAudio       // POST /v1/chat/completions, input_audio block
    case transcriptionMultipart     // POST /v1|v2/audio/transcriptions, multipart
    case elevenLabsScribe           // ElevenLabs Scribe, own field names
    case geminiGenerateContent      // Gemini File API + generateContent
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobShapeBehavior`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift
git commit -m "feat(jobs): add JobShape enum"
```

---

## Task 3: `FieldSpec` + `JobShape.fields`

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift`

- [ ] **Step 1: Add failing tests for `JobShape.fields`**

Append to `JobShapeTests.swift`:

```swift
@Suite struct JobShapeFields {
    @Test func chatCompletionsAudio_hasPromptAndTemperature() {
        let keys = JobShape.chatCompletionsAudio.fields.map(\.key)
        #expect(keys.contains("prompt"))
        #expect(keys.contains("temperature"))
    }

    @Test func transcriptionMultipart_hasLanguageAndResponseFormat() {
        let keys = JobShape.transcriptionMultipart.fields.map(\.key)
        #expect(keys.contains("language"))
        #expect(keys.contains("response_format"))
    }

    @Test func elevenLabsScribe_usesItsOwnFieldNames() {
        let keys = JobShape.elevenLabsScribe.fields.map(\.key)
        #expect(keys.contains("language_code"))
        #expect(keys.contains("diarize"))
    }

    @Test func gemini_hasThinkingBudget() {
        let keys = JobShape.geminiGenerateContent.fields.map(\.key)
        #expect(keys.contains("thinkingBudget"))
    }

    @Test(arguments: JobShape.allCases)
    func allShapes_haveAtLeastOneField(shape: JobShape) {
        #expect(!shape.fields.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobShapeFields`
Expected: FAIL — `fields` undefined.

- [ ] **Step 3: Implement `FieldSpec` + extension**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift`:

```swift
import Foundation

// UI form metadata. The Job stores values as [String: String]; this drives
// rendering, validation, and per-shape required/optional rules.
public struct FieldSpec: Hashable, Sendable {
    public let key: String
    public let label: String
    public let kind: Kind
    public let required: Bool
    public let help: String?

    public enum Kind: Hashable, Sendable {
        case text
        case longText
        case number
        case language               // ISO-639-1 code
        case picker([String])
        case checkbox
    }

    public init(key: String, label: String, kind: Kind, required: Bool, help: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.required = required
        self.help = help
    }
}

extension JobShape {
    public var fields: [FieldSpec] {
        switch self {
        case .chatCompletionsAudio:
            return [
                FieldSpec(key: "prompt", label: "Prompt", kind: .longText, required: true,
                          help: "Instructions for the model (system+user)"),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
                FieldSpec(key: "audio_format", label: "Audio format hint", kind: .picker(["auto", "flac", "wav", "mp3"]),
                          required: false, help: "Sent as input_audio.format. 'auto' derives from file extension."),
            ]
        case .transcriptionMultipart:
            return [
                FieldSpec(key: "prompt", label: "Vocabulary biasing", kind: .text, required: false,
                          help: "~224 tokens, NOT instructions"),
                FieldSpec(key: "language", label: "Language", kind: .language, required: false,
                          help: "ISO-639-1; required for Cohere"),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
                FieldSpec(key: "response_format", label: "Response format",
                          kind: .picker(["json", "text", "verbose_json", "srt", "vtt"]), required: false),
            ]
        case .elevenLabsScribe:
            return [
                FieldSpec(key: "language_code", label: "Language", kind: .language, required: false),
                FieldSpec(key: "diarize", label: "Speaker diarization", kind: .checkbox, required: false),
                FieldSpec(key: "num_speakers", label: "Number of speakers", kind: .number, required: false),
                FieldSpec(key: "timestamps_granularity", label: "Timestamps",
                          kind: .picker(["none", "word", "character"]), required: false),
                FieldSpec(key: "tag_audio_events", label: "Tag non-speech events", kind: .checkbox, required: false),
            ]
        case .geminiGenerateContent:
            return [
                FieldSpec(key: "prompt", label: "Prompt", kind: .longText, required: true),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
                FieldSpec(key: "thinkingBudget", label: "Thinking budget", kind: .number, required: false,
                          help: "Reasoning tokens; 0 disables"),
            ]
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobShape`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift
git commit -m "feat(jobs): add FieldSpec and per-shape field schemas"
```

---

## Task 4: `Preset` + Codable

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Preset.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct PresetCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let preset = Preset(
            id: "openai-compat-chat",
            displayName: "OpenAI-compatible Chat",
            shape: .chatCompletionsAudio,
            baseURL: "https://example.com",
            suggestedModels: ["gpt-4o-audio-preview"],
            defaults: ["temperature": "0.2"],
            docsURL: "https://docs.example.com"
        )
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        #expect(decoded == preset)
    }

    @Test func docsURL_isOptional() throws {
        let json = #"""
        {"id":"x","displayName":"X","shape":"chatCompletionsAudio",
         "baseURL":"","suggestedModels":[],"defaults":{}}
        """#
        let decoded = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        #expect(decoded.docsURL == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter PresetCodable`
Expected: FAIL — `Preset` undefined.

- [ ] **Step 3: Implement `Preset`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/Preset.swift`:

```swift
import Foundation

// Shipped template that pre-fills a Job. Read from bundled presets.json at
// startup; not user-editable in this slice.
public struct Preset: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shape: JobShape
    public let baseURL: String          // empty => user must fill (generic compat)
    public let suggestedModels: [String]
    public let defaults: [String: String]
    public let docsURL: String?

    public init(id: String, displayName: String, shape: JobShape,
                baseURL: String, suggestedModels: [String],
                defaults: [String: String], docsURL: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.shape = shape
        self.baseURL = baseURL
        self.suggestedModels = suggestedModels
        self.defaults = defaults
        self.docsURL = docsURL
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter PresetCodable`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Preset.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetTests.swift
git commit -m "feat(jobs): add Preset struct"
```

---

## Task 5: `KeychainRef` + `Job`

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainRef.swift`
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let job = Job(
            id: id,
            name: "Swedish lesson transcription",
            presetID: "openai-compat-chat",
            baseURL: "http://localhost:4444/openai",
            model: "gemini-flash",
            apiKeyRef: KeychainRef(account: "bifrost-local"),
            fields: ["prompt": "Transcribe...", "temperature": "0.2"],
            outputExt: "txt"
        )
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded == job)
    }

    @Test func id_isStable_acrossEdits() {
        let id = UUID()
        var job = Job(id: id, name: "a", presetID: "x", baseURL: "",
                      model: "", apiKeyRef: KeychainRef(account: ""),
                      fields: [:], outputExt: "txt")
        job.name = "b"
        #expect(job.id == id)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobCodable`
Expected: FAIL — `Job`/`KeychainRef` undefined.

- [ ] **Step 3: Implement `KeychainRef`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainRef.swift`:

```swift
import Foundation

// A name pointing at a Keychain entry. The actual secret never travels with
// the Job; it's fetched from KeychainStore at run time.
public struct KeychainRef: Codable, Hashable, Sendable {
    public let account: String      // user-chosen label, e.g. "openai-personal"

    public init(account: String) {
        self.account = account
    }
}
```

- [ ] **Step 4: Implement `Job`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift`:

```swift
import Foundation

// User-saved configuration for one audio→text run. Many Jobs may share a
// presetID. Stored as JSON on disk via JobsStore.
public struct Job: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String                 // user label, e.g. "Swedish lesson"
    public var presetID: String             // links back to Preset
    public var baseURL: String              // may diverge from preset (self-hosted)
    public var model: String                // free text; preset.suggestedModels is just autocomplete
    public var apiKeyRef: KeychainRef
    public var fields: [String: String]     // shape-specific values
    public var outputExt: String            // "txt", "json", "srt"

    public init(id: UUID = UUID(), name: String, presetID: String,
                baseURL: String, model: String, apiKeyRef: KeychainRef,
                fields: [String: String], outputExt: String) {
        self.id = id
        self.name = name
        self.presetID = presetID
        self.baseURL = baseURL
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.fields = fields
        self.outputExt = outputExt
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobCodable`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainRef.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobTests.swift
git commit -m "feat(jobs): add Job and KeychainRef structs"
```

---

## Task 6: `KeychainStore` actor

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainStore.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/KeychainStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

// Each test uses a unique service so concurrent runs and prior failures
// don't collide. teardown wipes everything under that service.
private func withFreshKeychain(_ body: (KeychainStore) async throws -> Void) async throws {
    let service = "work.miklos.audio-pipeline.test-\(UUID().uuidString)"
    let store = KeychainStore(service: service)
    do {
        try await body(store)
        try? await store.deleteAll()
    } catch {
        try? await store.deleteAll()
        throw error
    }
}

@Suite struct KeychainStoreBehavior {
    @Test func set_then_get_returnsTheKey() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "test-account", key: "sk-secret-123")
            let value = try await store.get(account: "test-account")
            #expect(value == "sk-secret-123")
        }
    }

    @Test func set_overwrites_existingValue() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "acc", key: "first")
            try await store.set(account: "acc", key: "second")
            let value = try await store.get(account: "acc")
            #expect(value == "second")
        }
    }

    @Test func list_returnsAllAccounts() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "a", key: "1")
            try await store.set(account: "b", key: "2")
            let accounts = try await store.list()
            #expect(Set(accounts) == ["a", "b"])
        }
    }

    @Test func delete_removesEntry() async throws {
        try await withFreshKeychain { store in
            try await store.set(account: "doomed", key: "x")
            try await store.delete(account: "doomed")
            do {
                _ = try await store.get(account: "doomed")
                Issue.record("expected get to throw after delete")
            } catch KeychainStore.Error.itemNotFound {
                // expected
            }
        }
    }

    @Test func get_unknownAccount_throwsItemNotFound() async throws {
        try await withFreshKeychain { store in
            do {
                _ = try await store.get(account: "missing")
                Issue.record("expected itemNotFound")
            } catch KeychainStore.Error.itemNotFound {
                // expected
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter KeychainStoreBehavior`
Expected: FAIL — `KeychainStore` undefined.

- [ ] **Step 3: Implement `KeychainStore`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainStore.swift`:

```swift
import Foundation
import Security

// Async wrapper around Security.framework. The actor serialises access so
// callers don't need to think about thread safety. Service id is injected;
// production uses the app's bundle id, tests use a per-run unique id.
public actor KeychainStore {
    public enum Error: Swift.Error, Equatable {
        case itemNotFound
        case unexpectedData
        case osStatus(OSStatus)
    }

    public static let defaultService = "work.miklos.audio-pipeline.api-keys"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func set(account: String, key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try update first; if missing, add. Cheaper than always delete+add.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Error.osStatus(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Error.osStatus(addStatus) }
    }

    public func get(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw Error.itemNotFound }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
        guard let data = result as? Data, let str = String(data: data, encoding: .utf8) else {
            throw Error.unexpectedData
        }
        return str
    }

    public func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw Error.osStatus(status) }
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw Error.osStatus(status)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter KeychainStoreBehavior`
Expected: PASS.

Note: if the SPM test process can't access the user Keychain due to sandbox, tests may need to be marked `@Test(.disabled(if: ProcessInfo.processInfo.environment["SANDBOXED"] != nil))` and run in Xcode via the app-hosted test target instead. Check first; only adjust if the test actually errors with `errSecMissingEntitlement` (−34018).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainStore.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/KeychainStoreTests.swift
git commit -m "feat(jobs): add KeychainStore actor"
```

---

## Task 7: `presets.json` resource + `PresetsStore`

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/PresetsStore.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift`

- [ ] **Step 1: Write `presets.json`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`:

```json
[
  {"id":"openai-chat-audio","displayName":"OpenAI Chat (audio)","shape":"chatCompletionsAudio",
   "baseURL":"https://api.openai.com","suggestedModels":["gpt-4o-audio-preview"],"defaults":{},
   "docsURL":"https://platform.openai.com/docs/guides/audio"},
  {"id":"openai-compat-chat","displayName":"OpenAI-compatible Chat","shape":"chatCompletionsAudio",
   "baseURL":"","suggestedModels":[],"defaults":{}},
  {"id":"openrouter","displayName":"OpenRouter","shape":"chatCompletionsAudio",
   "baseURL":"https://openrouter.ai/api","suggestedModels":[],"defaults":{},
   "docsURL":"https://openrouter.ai/docs"},
  {"id":"openai-whisper","displayName":"OpenAI Whisper / gpt-4o-transcribe","shape":"transcriptionMultipart",
   "baseURL":"https://api.openai.com","suggestedModels":["whisper-1","gpt-4o-transcribe","gpt-4o-mini-transcribe"],
   "defaults":{},"docsURL":"https://platform.openai.com/docs/api-reference/audio/createTranscription"},
  {"id":"mistral-voxtral","displayName":"Mistral Voxtral","shape":"transcriptionMultipart",
   "baseURL":"https://api.mistral.ai","suggestedModels":["voxtral-mini-2602"],"defaults":{},
   "docsURL":"https://docs.mistral.ai/capabilities/audio/"},
  {"id":"groq-whisper","displayName":"Groq Whisper","shape":"transcriptionMultipart",
   "baseURL":"https://api.groq.com/openai","suggestedModels":["whisper-large-v3","whisper-large-v3-turbo"],
   "defaults":{},"docsURL":"https://console.groq.com/docs/speech-text"},
  {"id":"cohere","displayName":"Cohere","shape":"transcriptionMultipart",
   "baseURL":"https://api.cohere.com","suggestedModels":["cohere-transcribe-03-2026"],"defaults":{},
   "docsURL":"https://docs.cohere.com/reference/create-audio-transcription"},
  {"id":"openai-compat-transcribe","displayName":"OpenAI-compatible Transcription","shape":"transcriptionMultipart",
   "baseURL":"","suggestedModels":[],"defaults":{}},
  {"id":"elevenlabs","displayName":"ElevenLabs Scribe","shape":"elevenLabsScribe",
   "baseURL":"https://api.elevenlabs.io","suggestedModels":["scribe_v1","scribe_v1_experimental"],
   "defaults":{"diarize":"true"},
   "docsURL":"https://elevenlabs.io/docs/api-reference/speech-to-text"},
  {"id":"gemini","displayName":"Gemini","shape":"geminiGenerateContent",
   "baseURL":"https://generativelanguage.googleapis.com/v1beta","suggestedModels":["gemini-2.5-flash","gemini-2.5-pro"],
   "defaults":{},"docsURL":"https://ai.google.dev/api/generate-content"}
]
```

- [ ] **Step 2: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct PresetsStoreBehavior {
    @Test func loadsAllBundledPresets() throws {
        let store = try PresetsStore.loadBundled()
        let ids = Set(store.all.map(\.id))
        #expect(ids.contains("openai-compat-chat"))
        #expect(ids.contains("mistral-voxtral"))
        #expect(ids.contains("cohere"))
        #expect(ids.contains("gemini"))
        #expect(ids.contains("openrouter"))
        #expect(store.all.count == 10)
    }

    @Test func lookupByID_returnsPreset() throws {
        let store = try PresetsStore.loadBundled()
        let preset = store.preset(id: "mistral-voxtral")
        #expect(preset?.shape == .transcriptionMultipart)
        #expect(preset?.suggestedModels.contains("voxtral-mini-2602") == true)
    }

    @Test func lookupByID_missing_returnsNil() throws {
        let store = try PresetsStore.loadBundled()
        #expect(store.preset(id: "does-not-exist") == nil)
    }

    @Test func openrouter_isChatShape() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "openrouter")
        #expect(p?.shape == .chatCompletionsAudio)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter PresetsStoreBehavior`
Expected: FAIL — `PresetsStore` undefined.

- [ ] **Step 4: Implement `PresetsStore`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/PresetsStore.swift`:

```swift
import Foundation

// Loads the bundled preset library once. Treated as read-only — the user
// edits Jobs, not Presets.
public struct PresetsStore: Sendable {
    public enum LoadError: Error {
        case resourceMissing
        case decodeFailed(Error)
    }

    public let all: [Preset]
    private let byID: [String: Preset]

    public init(presets: [Preset]) {
        self.all = presets
        self.byID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
    }

    public func preset(id: String) -> Preset? {
        byID[id]
    }

    public static func loadBundled() throws -> PresetsStore {
        guard let url = Bundle.module.url(forResource: "presets", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        do {
            let data = try Data(contentsOf: url)
            let presets = try JSONDecoder().decode([Preset].self, from: data)
            return PresetsStore(presets: presets)
        } catch {
            throw LoadError.decodeFailed(error)
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter PresetsStoreBehavior`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/PresetsStore.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift
git commit -m "feat(jobs): bundle presets.json and load via PresetsStore"
```

---

## Task 8: `JobsStore` (observable, JSON-on-disk)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobsStore.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func tempFile() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    return dir.appendingPathComponent("jobs-\(UUID().uuidString).json")
}

private func makeJob(name: String = "demo") -> Job {
    Job(name: name, presetID: "openai-compat-chat",
        baseURL: "http://localhost:4444/openai",
        model: "gemini-flash",
        apiKeyRef: KeychainRef(account: "bifrost"),
        fields: ["prompt": "Transcribe this."],
        outputExt: "txt")
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

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobsStoreBehavior`
Expected: FAIL — `JobsStore` undefined.

- [ ] **Step 3: Implement `JobsStore`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/JobsStore.swift`:

```swift
import Foundation
import Observation

// Persistent list of Jobs. JSON-on-disk in Application Support. Observable so
// the Jobs settings panel re-renders on CRUD.
@MainActor
@Observable
public final class JobsStore {
    public private(set) var jobs: [Job] = []

    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try load()
    }

    // Constructs a JobsStore at the standard app location:
    //   Application Support/<bundleID>/jobs.json
    public static func standard(bundleID: String) throws -> JobsStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try JobsStore(fileURL: dir.appendingPathComponent("jobs.json"))
    }

    public func upsert(_ job: Job) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.append(job)
        }
        save()
    }

    public func delete(id: UUID) {
        jobs.removeAll { $0.id == id }
        save()
    }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        jobs = try JSONDecoder().decode([Job].self, from: data)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal for the in-memory store but worth
            // logging. Defer to OSLog from the app composition root if needed.
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobsStoreBehavior`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobsStore.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobsStoreTests.swift
git commit -m "feat(jobs): add observable JobsStore with JSON persistence"
```

---

## Task 9: `ChatCompletionsAudioHandler` — request builder

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift`

- [ ] **Step 1: Write the failing tests for request construction**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeJob(prompt: String, model: String = "gemini-flash",
                     baseURL: String = "http://localhost:4444/openai",
                     audioFormat: String? = nil,
                     temperature: String? = nil) -> Job {
    var fields: [String: String] = ["prompt": prompt]
    if let audioFormat { fields["audio_format"] = audioFormat }
    if let temperature { fields["temperature"] = temperature }
    return Job(name: "t", presetID: "openai-compat-chat",
               baseURL: baseURL, model: model,
               apiKeyRef: KeychainRef(account: "bifrost"),
               fields: fields, outputExt: "txt")
}

private func writeAudio(_ bytes: [UInt8], ext: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).\(ext)")
    try Data(bytes).write(to: url)
    return url
}

@Suite struct ChatCompletionsAudioRequest {
    @Test func buildsPOST_toChatCompletionsPath() throws {
        let job = makeJob(prompt: "Hello")
        let audio = try writeAudio([0x01, 0x02], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://localhost:4444/openai/v1/chat/completions")
    }

    @Test func authorizationHeader_isBearerToken() throws {
        let job = makeJob(prompt: "Hello")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "sk-x")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func body_encodesModelMessagesAndBase64Audio() throws {
        let job = makeJob(prompt: "Transcribe.")
        let audio = try writeAudio([0xAA, 0xBB, 0xCC], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "gemini-flash")
        let messages = try #require(json?["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let inputAudio = try #require(content.first { $0["type"] as? String == "input_audio" })
        let audioObj = try #require(inputAudio["input_audio"] as? [String: Any])
        #expect(audioObj["data"] as? String == Data([0xAA, 0xBB, 0xCC]).base64EncodedString())
        #expect(audioObj["format"] as? String == "flac")
        let text = try #require(content.first { $0["type"] as? String == "text" })
        #expect(text["text"] as? String == "Transcribe.")
    }

    @Test func audioFormat_auto_derivesFromExtension() throws {
        let job = makeJob(prompt: "p", audioFormat: "auto")
        let audio = try writeAudio([0x01], ext: "wav")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let inputAudio = try #require(content.first { $0["type"] as? String == "input_audio" })
        let audioObj = try #require(inputAudio["input_audio"] as? [String: Any])
        #expect(audioObj["format"] as? String == "wav")
    }

    @Test func temperature_isIncludedWhenSet() throws {
        let job = makeJob(prompt: "p", temperature: "0.3")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["temperature"] as? Double == 0.3)
    }

    @Test func temperature_isOmittedWhenAbsent() throws {
        let job = makeJob(prompt: "p")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["temperature"] == nil)
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let job = makeJob(prompt: "p", baseURL: "http://example.com/")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        #expect(req.url?.absoluteString == "http://example.com/v1/chat/completions")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ChatCompletionsAudioRequest`
Expected: FAIL — handler undefined.

- [ ] **Step 3: Implement the request builder**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift`:

```swift
import Foundation

// HTTP handler for the OpenAI-compatible chat-completions endpoint with an
// input_audio content block (the "openai-file-b64" shape).
//
// Wire shape:
//   POST {baseURL}/v1/chat/completions
//   Authorization: Bearer <key>
//   Content-Type: application/json
//   {
//     "model": "...",
//     "messages": [{"role": "user", "content": [
//        {"type": "input_audio", "input_audio": {"data": "<base64>", "format": "flac"}},
//        {"type": "text", "text": "<prompt>"}
//     ]}],
//     "temperature": 0.3  // optional
//   }
public enum ChatCompletionsAudioHandler {
    public enum BuildError: Error, Equatable {
        case missingPrompt
        case invalidBaseURL
        case audioReadFailed
    }

    public static func buildRequest(job: Job, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard let prompt = job.fields["prompt"], !prompt.isEmpty else {
            throw BuildError.missingPrompt
        }

        let trimmedBase = job.baseURL.hasSuffix("/") ? String(job.baseURL.dropLast()) : job.baseURL
        guard let endpoint = URL(string: trimmedBase + "/v1/chat/completions") else {
            throw BuildError.invalidBaseURL
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        let format = resolveFormat(declared: job.fields["audio_format"], audioURL: audioURL)

        var contentBlocks: [[String: Any]] = [
            ["type": "input_audio",
             "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": format,
             ]],
            ["type": "text", "text": prompt],
        ]
        _ = contentBlocks  // silence "may be unused" if ever reordered

        var body: [String: Any] = [
            "model": job.model,
            "messages": [
                ["role": "user", "content": contentBlocks],
            ],
        ]
        if let tempStr = job.fields["temperature"], let temp = Double(tempStr) {
            body["temperature"] = temp
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private static func resolveFormat(declared: String?, audioURL: URL) -> String {
        if let declared, declared != "auto", !declared.isEmpty {
            return declared
        }
        let ext = audioURL.pathExtension.lowercased()
        return ext.isEmpty ? "flac" : ext
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ChatCompletionsAudioRequest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift
git commit -m "feat(jobs): ChatCompletionsAudioHandler request builder"
```

---

## Task 10: `ChatCompletionsAudioHandler` — response parser + send

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift`

- [ ] **Step 1: Write the failing tests for response parsing + send**

Append to `ChatCompletionsAudioHandlerTests.swift`:

```swift
// URLProtocol stub that returns a fixed (Data, HTTPURLResponse) pair for
// every request and records the last URLRequest seen.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data)?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let (status, body) = Self.response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession(status: Int, body: Data) -> URLSession {
    StubProtocol.response = (status, body)
    StubProtocol.lastRequest = nil
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

@Suite struct ChatCompletionsAudioResponse {
    @Test func send_returnsContent_onSuccess() async throws {
        let json = #"{"choices":[{"message":{"content":"Hello world"}}]}"#
        let session = stubSession(status: 200, body: Data(json.utf8))
        let job = makeJob(prompt: "p")
        let audio = try writeAudio([0x01], ext: "flac")
        let text = try await ChatCompletionsAudioHandler.send(job: job, audioURL: audio,
                                                              apiKey: "k", session: session)
        #expect(text == "Hello world")
    }

    @Test func send_throws_onNon200() async throws {
        let session = stubSession(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        let job = makeJob(prompt: "p")
        let audio = try writeAudio([0x01], ext: "flac")
        do {
            _ = try await ChatCompletionsAudioHandler.send(job: job, audioURL: audio,
                                                          apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch ChatCompletionsAudioHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }

    @Test func send_throws_whenChoicesMissing() async throws {
        let session = stubSession(status: 200, body: Data(#"{"unexpected":true}"#.utf8))
        let job = makeJob(prompt: "p")
        let audio = try writeAudio([0x01], ext: "flac")
        do {
            _ = try await ChatCompletionsAudioHandler.send(job: job, audioURL: audio,
                                                          apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch ChatCompletionsAudioHandler.SendError.malformedResponse {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ChatCompletionsAudioResponse`
Expected: FAIL — `send` undefined.

- [ ] **Step 3: Extend the handler with `send`**

Append to `ChatCompletionsAudioHandler.swift`:

```swift
extension ChatCompletionsAudioHandler {
    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
    }

    public static func send(
        job: Job,
        audioURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let request = try buildRequest(job: job, audioURL: audioURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try parseContent(data: data)
    }

    static func parseContent(data: Data) throws -> String {
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            guard let first = env.choices.first else { throw SendError.malformedResponse }
            return first.message.content
        } catch is SendError {
            throw SendError.malformedResponse
        } catch {
            throw SendError.malformedResponse
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ChatCompletionsAudio`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ChatCompletionsAudioHandlerTests.swift
git commit -m "feat(jobs): ChatCompletionsAudioHandler send + response parsing"
```

---

## Task 11: `JobRunner`

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

// Fake keychain that returns a fixed key without touching Security.framework.
private actor FakeKeychain: KeychainProviding {
    let key: String
    init(key: String) { self.key = key }
    func get(account: String) async throws -> String { key }
}

private actor FakeHandler: ChatCompletionsAudioSending {
    private(set) var lastJob: Job?
    private(set) var lastAudio: URL?
    private(set) var lastKey: String?
    let result: Result<String, Error>
    init(result: Result<String, Error>) { self.result = result }
    func send(job: Job, audioURL: URL, apiKey: String) async throws -> String {
        lastJob = job; lastAudio = audioURL; lastKey = apiKey
        return try result.get()
    }
}

private func makeJob(outputExt: String = "txt") -> Job {
    Job(name: "demo", presetID: "openai-compat-chat",
        baseURL: "http://x", model: "m",
        apiKeyRef: KeychainRef(account: "acc"),
        fields: ["prompt": "p"], outputExt: outputExt)
}

private func makeAudio() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rec-\(UUID().uuidString).flac")
    try Data([0x01, 0x02]).write(to: url)
    return url
}

@Suite struct JobRunnerBehavior {
    @Test func run_writesOutputFile_nextToRecording() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-x")
        let handler = FakeHandler(result: .success("transcribed text"))
        let runner = JobRunner(keychain: keychain, handler: handler)
        let outURL = try await runner.run(job: makeJob(), audioURL: audio)
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "transcribed text")
        #expect(outURL.pathExtension == "txt")
        #expect(outURL.deletingPathExtension().lastPathComponent
                == audio.deletingPathExtension().lastPathComponent)
    }

    @Test func run_passesKeyAndJob_toHandler() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-real")
        let handler = FakeHandler(result: .success("ok"))
        let runner = JobRunner(keychain: keychain, handler: handler)
        let job = makeJob()
        _ = try await runner.run(job: job, audioURL: audio)
        #expect(await handler.lastKey == "sk-real")
        #expect(await handler.lastJob?.id == job.id)
        #expect(await handler.lastAudio == audio)
    }

    @Test func run_propagatesHandlerErrors() async throws {
        struct Boom: Error {}
        let audio = try makeAudio()
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handler: FakeHandler(result: .failure(Boom())))
        do {
            _ = try await runner.run(job: makeJob(), audioURL: audio)
            Issue.record("expected throw")
        } catch is Boom {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobRunnerBehavior`
Expected: FAIL — `JobRunner` undefined.

- [ ] **Step 3: Add protocol abstractions to the existing files**

Append to `KeychainStore.swift`:

```swift
// Minimal protocol so JobRunner can be tested with a fake.
public protocol KeychainProviding: Sendable {
    func get(account: String) async throws -> String
}

extension KeychainStore: KeychainProviding {}
```

Append to `ChatCompletionsAudioHandler.swift`:

```swift
// Mirror of the static `send` as a protocol, so JobRunner can be tested
// without making real network calls.
public protocol ChatCompletionsAudioSending: Sendable {
    func send(job: Job, audioURL: URL, apiKey: String) async throws -> String
}

public struct DefaultChatCompletionsAudioSender: ChatCompletionsAudioSending {
    public init() {}
    public func send(job: Job, audioURL: URL, apiKey: String) async throws -> String {
        try await ChatCompletionsAudioHandler.send(job: job, audioURL: audioURL, apiKey: apiKey)
    }
}
```

- [ ] **Step 4: Implement `JobRunner`**

`Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`:

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
    public func run(job: Job, audioURL: URL) async throws -> URL {
        let key = try await keychain.get(account: job.apiKeyRef.account)
        let text = try await handler.send(job: job, audioURL: audioURL, apiKey: key)
        let outURL = audioURL.deletingPathExtension().appendingPathExtension(job.outputExt)
        try text.data(using: .utf8)?.write(to: outURL, options: .atomic)
        return outURL
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobRunnerBehavior`
Expected: PASS. Also re-run full SPM suite to confirm no regressions:
`swift test --disable-sandbox --package-path Packages/AudioPipeline`

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/KeychainStore.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift
git commit -m "feat(jobs): JobRunner orchestrates handler + output write"
```

---

## Task 12: Wire stores into `AppCoordinator`

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Add imports and stored properties**

Edit `audio-pipeline/AppCoordinator.swift`. After `import RecordingStorage`, add:

```swift
import AudioPipelineJobs
```

Inside the `AppCoordinator` class, after `let library: RecordingsLibrary`, add:

```swift
let keychain: KeychainStore
let presets: PresetsStore
let jobs: JobsStore
```

- [ ] **Step 2: Initialise the new stores in `init()`**

Replace the body of `init()` with:

```swift
init() {
    let settings = AppSettings()
    self.settings = settings
    self.library = RecordingsLibrary { settings.recordingsDirectory }
    self.keychain = KeychainStore()
    do {
        self.presets = try PresetsStore.loadBundled()
    } catch {
        Self.log.error("failed to load presets: \(String(describing: error), privacy: .public)")
        self.presets = PresetsStore(presets: [])
    }
    do {
        self.jobs = try JobsStore.standard(bundleID: "work.miklos.audio-pipeline")
    } catch {
        Self.log.error("failed to load jobs: \(String(describing: error), privacy: .public)")
        // Last-resort in-memory store at a throwaway temp path.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jobs-fallback.json")
        self.jobs = (try? JobsStore(fileURL: tmp)) ?? {
            preconditionFailure("could not initialise JobsStore even at temp path")
        }()
    }
}
```

- [ ] **Step 3: Build the app**

Run via xcode-build skill: `xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "feat(jobs): wire KeychainStore, PresetsStore, JobsStore into AppCoordinator"
```

---

## Task 13: Settings tab structure (Recording + Jobs)

**Files:**
- Modify: `audio-pipeline/UI/SettingsView.swift`
- Create: `audio-pipeline/UI/Jobs/JobsSettingsPanel.swift`

- [ ] **Step 1: Convert `SettingsView` to a TabView**

Replace `audio-pipeline/UI/SettingsView.swift` body with:

```swift
import AppKit
import AppSettings
import AudioPipelineJobs
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let presets: PresetsStore
    let jobs: JobsStore
    let keychain: KeychainStore

    var body: some View {
        TabView {
            RecordingSettingsTab(settings: settings)
                .tabItem { Label("Recording", systemImage: "mic") }
            JobsSettingsPanel(presets: presets, jobs: jobs, keychain: keychain)
                .tabItem { Label("Jobs", systemImage: "wand.and.stars") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct RecordingSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(settings.recordingsDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseLocation)
                    }
                }
            }
            Section("Output format") {
                Picker("When a recording stops", selection: $settings.outputFormat) {
                    ForEach(AppSettings.OutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingsDirectory = url
        }
    }
}
```

- [ ] **Step 2: Create the Jobs panel shell**

`audio-pipeline/UI/Jobs/JobsSettingsPanel.swift`:

```swift
import AudioPipelineJobs
import SwiftUI

struct JobsSettingsPanel: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    let keychain: KeychainStore

    @State private var selectedJobID: UUID?
    @State private var editing: Job?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedJobID) {
                ForEach(jobs.jobs) { job in
                    JobRow(job: job, preset: presets.preset(id: job.presetID))
                        .tag(Optional(job.id))
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 8) {
                Button { creating = true } label: { Image(systemName: "plus") }
                Button {
                    if let id = selectedJobID, let job = jobs.jobs.first(where: { $0.id == id }) {
                        editing = job
                    }
                } label: { Image(systemName: "pencil") }
                .disabled(selectedJobID == nil)
                Button {
                    if let id = selectedJobID { jobs.delete(id: id); selectedJobID = nil }
                } label: { Image(systemName: "minus") }
                .disabled(selectedJobID == nil)
                Spacer()
            }
            .padding(8)
        }
        .sheet(item: $editing) { job in
            JobEditorView(initial: job, presets: presets, keychain: keychain) { updated in
                jobs.upsert(updated)
            }
        }
        .sheet(isPresented: $creating) {
            JobEditorView(initial: nil, presets: presets, keychain: keychain) { created in
                jobs.upsert(created)
            }
        }
    }
}

private struct JobRow: View {
    let job: Job
    let preset: Preset?

    var body: some View {
        VStack(alignment: .leading) {
            Text(job.name).font(.headline)
            HStack(spacing: 6) {
                Text(preset?.displayName ?? job.presetID)
                Text("·")
                Text(job.model.isEmpty ? "—" : job.model)
            }
            .foregroundStyle(.secondary)
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 3: Wire SettingsView call sites**

Find where `SettingsView(settings:)` is constructed (likely `audio_pipelineApp.swift` or a `Settings` scene). Update the call site to pass the new dependencies:

```swift
SettingsView(settings: coordinator.settings,
             presets: coordinator.presets,
             jobs: coordinator.jobs,
             keychain: coordinator.keychain)
```

- [ ] **Step 4: Build (will fail until JobEditorView exists)**

Skip building until Task 14 lands `JobEditorView`. The current file references it but it doesn't exist yet — that's expected.

- [ ] **Step 5: Commit the panel shell**

```bash
git add audio-pipeline/UI/SettingsView.swift \
        audio-pipeline/UI/Jobs/JobsSettingsPanel.swift \
        audio-pipeline/audio_pipelineApp.swift  # if call site updated here
git commit -m "feat(jobs): Jobs settings tab + JobsSettingsPanel shell"
```

---

## Task 14: `JobEditorView` + `JobFieldFormView`

**Files:**
- Create: `audio-pipeline/UI/Jobs/JobEditorView.swift`
- Create: `audio-pipeline/UI/Jobs/JobFieldFormView.swift`

- [ ] **Step 1: Implement the editor sheet**

`audio-pipeline/UI/Jobs/JobEditorView.swift`:

```swift
import AudioPipelineJobs
import SwiftUI

struct JobEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var presetID: String
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKeyAccount: String
    @State private var fields: [String: String]
    @State private var outputExt: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let keychain: KeychainStore
    private let onSave: (Job) -> Void

    init(initial: Job?, presets: PresetsStore, keychain: KeychainStore,
         onSave: @escaping (Job) -> Void) {
        self.presets = presets
        self.keychain = keychain
        self.onSave = onSave

        let firstPreset = presets.all.first
        let starting = initial ?? Job(
            name: "Untitled",
            presetID: firstPreset?.id ?? "",
            baseURL: firstPreset?.baseURL ?? "",
            model: firstPreset?.suggestedModels.first ?? "",
            apiKeyRef: KeychainRef(account: ""),
            fields: firstPreset?.defaults ?? [:],
            outputExt: "txt"
        )
        self.initialID = starting.id
        _name = State(initialValue: starting.name)
        _presetID = State(initialValue: starting.presetID)
        _baseURL = State(initialValue: starting.baseURL)
        _model = State(initialValue: starting.model)
        _apiKeyAccount = State(initialValue: starting.apiKeyRef.account)
        _fields = State(initialValue: starting.fields)
        _outputExt = State(initialValue: starting.outputExt)
    }

    private var preset: Preset? { presets.preset(id: presetID) }
    private var shape: JobShape? { preset?.shape }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Job").font(.title2).padding([.top, .horizontal])

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
                        if model.isEmpty { model = p.suggestedModels.first ?? "" }
                        for (k, v) in p.defaults where fields[k] == nil { fields[k] = v }
                    }
                    TextField("Base URL", text: $baseURL)
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
                    KeychainAccountPicker(account: $apiKeyAccount, keychain: keychain)
                    TextField("Output extension", text: $outputExt)
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
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 540, height: 560)
    }

    private var canSave: Bool {
        !name.isEmpty && !presetID.isEmpty && !apiKeyAccount.isEmpty && !model.isEmpty
    }

    private func save() {
        let job = Job(id: initialID, name: name, presetID: presetID,
                      baseURL: baseURL, model: model,
                      apiKeyRef: KeychainRef(account: apiKeyAccount),
                      fields: fields, outputExt: outputExt)
        onSave(job)
        dismiss()
    }
}
```

- [ ] **Step 2: Implement the auto-generated form**

`audio-pipeline/UI/Jobs/JobFieldFormView.swift`:

```swift
import AudioPipelineJobs
import SwiftUI

struct JobFieldFormView: View {
    let shape: JobShape
    @Binding var values: [String: String]

    var body: some View {
        ForEach(shape.fields, id: \.key) { spec in
            row(spec)
        }
    }

    @ViewBuilder
    private func row(_ spec: FieldSpec) -> some View {
        switch spec.kind {
        case .text:
            field(spec) { TextField("", text: binding(spec.key)) }
        case .longText:
            field(spec) {
                TextEditor(text: binding(spec.key))
                    .frame(minHeight: 88)
                    .font(.body.monospaced())
            }
        case .number:
            field(spec) { TextField("", text: binding(spec.key)) }
        case .language:
            field(spec) {
                TextField("ISO-639-1 (e.g. sv, en)", text: binding(spec.key))
                    .textCase(.lowercase)
            }
        case .picker(let options):
            field(spec) {
                Picker("", selection: binding(spec.key)) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
        case .checkbox:
            Toggle(isOn: boolBinding(spec.key)) {
                VStack(alignment: .leading) {
                    Text(label(spec))
                    if let help = spec.help {
                        Text(help).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ spec: FieldSpec, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label(spec)).font(.subheadline)
            content()
            if let help = spec.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ spec: FieldSpec) -> String {
        spec.required ? "\(spec.label) *" : spec.label
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { (values[key] ?? "false") == "true" },
            set: { values[key] = $0 ? "true" : "false" }
        )
    }
}
```

- [ ] **Step 3: Build (will fail until KeychainAccountPicker exists)**

Continue to Task 15.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/UI/Jobs/JobEditorView.swift \
        audio-pipeline/UI/Jobs/JobFieldFormView.swift
git commit -m "feat(jobs): JobEditorView and auto-generated field form"
```

---

## Task 15: `KeychainAccountPicker`

**Files:**
- Create: `audio-pipeline/UI/Jobs/KeychainAccountPicker.swift`

- [ ] **Step 1: Implement the picker**

`audio-pipeline/UI/Jobs/KeychainAccountPicker.swift`:

```swift
import AudioPipelineJobs
import SwiftUI

struct KeychainAccountPicker: View {
    @Binding var account: String
    let keychain: KeychainStore

    @State private var accounts: [String] = []
    @State private var creating = false
    @State private var newAccount = ""
    @State private var newKey = ""
    @State private var loadError: String?

    var body: some View {
        HStack {
            Picker("API key", selection: $account) {
                Text("Select…").tag("")
                ForEach(accounts, id: \.self) { Text($0).tag($0) }
            }
            Button("New…") { creating = true }
        }
        .task { await refresh() }
        .sheet(isPresented: $creating) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add API key").font(.title3)
                TextField("Label (e.g. openai-personal)", text: $newAccount)
                SecureField("Secret", text: $newKey)
                HStack {
                    Spacer()
                    Button("Cancel") { creating = false; newAccount = ""; newKey = "" }
                    Button("Save") {
                        Task { await save() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newAccount.isEmpty || newKey.isEmpty)
                }
            }
            .padding(16)
            .frame(width: 360)
        }
        .alert("Keychain error", isPresented: Binding(get: { loadError != nil },
                                                       set: { _ in loadError = nil })) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private func refresh() async {
        do {
            accounts = try await keychain.list().sorted()
        } catch {
            loadError = String(describing: error)
        }
    }

    private func save() async {
        do {
            try await keychain.set(account: newAccount, key: newKey)
            let saved = newAccount
            creating = false
            newAccount = ""; newKey = ""
            await refresh()
            account = saved
        } catch {
            loadError = String(describing: error)
        }
    }
}
```

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Smoke-test the UI manually**

Open the app, open Settings → Jobs tab. Verify:
- Empty list shows; "+" button opens the editor.
- Editor's Preset picker lists all 10 entries.
- Selecting different presets updates the base URL and parameters section live.
- "New…" key sheet saves to Keychain and the picker refreshes.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/UI/Jobs/KeychainAccountPicker.swift
git commit -m "feat(jobs): KeychainAccountPicker with add-new flow"
```

---

## Task 16: Right-click "Run Job" on Recordings

**Files:**
- Modify: `audio-pipeline/UI/RecordingsView.swift`

- [ ] **Step 1: Read the current RecordingsView to find the row construction**

Read `audio-pipeline/UI/RecordingsView.swift` and identify where each recording is rendered as a list row. The context menu attaches to that row.

- [ ] **Step 2: Add `JobRunner` lookup helper on `AppCoordinator`**

In `audio-pipeline/AppCoordinator.swift`, add a method:

```swift
func runJob(_ job: Job, on recordingFolder: URL) async -> Result<URL, Error> {
    let audioURL = recordingFolder.appendingPathComponent("mic.flac")
    // Fall back to system.flac or original .caf if mic.flac is absent. Keep
    // the slice simple — use whatever the conversion settled on.
    let candidates = ["mic.flac", "system.flac", "mic.caf"]
    var chosen: URL?
    for name in candidates {
        let url = recordingFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { chosen = url; break }
    }
    let target = chosen ?? audioURL
    let runner = JobRunner(keychain: keychain)
    do {
        let out = try await runner.run(job: job, audioURL: target)
        return .success(out)
    } catch {
        Self.log.error("job '\(job.name, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
        return .failure(error)
    }
}
```

- [ ] **Step 3: Add a `runJob` context menu to each recording row**

In `RecordingsView.swift`, on the recording row view, add:

```swift
.contextMenu {
    if coordinator.jobs.jobs.isEmpty {
        Text("No Jobs defined")
    } else {
        Menu("Run Job") {
            ForEach(coordinator.jobs.jobs) { job in
                Button(job.name) {
                    Task {
                        let result = await coordinator.runJob(job, on: recording.url)
                        switch result {
                        case .success(let out):
                            NSWorkspace.shared.activateFileViewerSelecting([out])
                        case .failure:
                            // Surface inline; for MVP, just log. Toasts later.
                            break
                        }
                    }
                }
            }
        }
    }
}
```

Adjust binding names (`recording.url`, `coordinator`) to whatever the file already uses; the structure is the contribution.

- [ ] **Step 4: Build the app**

Run: `xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift audio-pipeline/UI/RecordingsView.swift
git commit -m "feat(jobs): right-click Run Job submenu on recordings"
```

---

## Task 17: End-to-end verification against the user's Bifrost

**Files:**
- None — manual verification.

- [ ] **Step 1: Configure a Job**

Launch the app. Open Settings → Jobs → "+":
- Name: `Bifrost chat (test)`
- Preset: `OpenAI-compatible Chat`
- Base URL: `http://localhost:4444/openai`
- Model: `gemini-flash`
- API key: New… → label `bifrost-local`, secret = the user's `BIFROST_API_KEY` value
- Prompt: `Transcribe the audio in its original language.`
- Output extension: `txt`

Save.

- [ ] **Step 2: Run it on a recording**

Right-click any recording → Run Job → `Bifrost chat (test)`. Wait for Finder to reveal the output file.

- [ ] **Step 3: Verify**

Expected:
- New file `<recording>/mic.txt` (or whichever source file was picked) contains the transcript.
- File opens cleanly in TextEdit; content is plain UTF-8 text.

If it fails:
- 401 → API key mismatch; recheck the Keychain entry.
- 404 → Bifrost not running, or path mismatch (verify base URL has no trailing `/chat/completions`).
- 5xx with HTML body → Bifrost likely proxying through a layer that doesn't accept `input_audio`; check `Console.app` for the request body or temporarily log it.

- [ ] **Step 4: Update CLAUDE.md**

Add an entry to the "Tests" section:

```
- `AudioPipelineJobsTests` (SPM): JobShape, Preset/Job Codable, JobsStore CRUD,
  ChatCompletionsAudioHandler request/response, JobRunner orchestration. The
  KeychainStore tests touch the real macOS Keychain under a per-run service id
  and self-clean.
```

- [ ] **Step 5: Final commit**

```bash
git add CLAUDE.md
git commit -m "docs: mention AudioPipelineJobsTests in CLAUDE.md"
```

---

## Self-Review

**Spec coverage:** every decision agreed in the design conversation is covered:
- 4 shapes enumerated, 1 fully implemented (chat+audio).
- Settings panel for Jobs (Task 13), right-click runner (Task 16).
- Multiple Jobs per Preset: enforced by `JobsStore.upsert` using `Job.id`; nothing constrains preset id uniqueness across jobs.
- Model name always user-editable: `Job.model` is free text; `suggestedModels` is a non-binding Menu in the editor.
- API keys in Keychain only; `Job` stores a `KeychainRef` (account string), never the raw secret.
- OpenRouter, Cohere (`cohere-transcribe-03-2026`), Mistral (`voxtral-mini-2602`), Gemini (`/v1beta`) all in `presets.json`.

**Deferred (intentional):**
- Handlers for `transcriptionMultipart`, `elevenLabsScribe`, `geminiGenerateContent`. Tracked by JobShape enum so future slices add a new sender + dispatch entry without touching the data model.
- "Test connection" button. The end-to-end Task 17 covers the same verification.
- Completion toast. `NSWorkspace.activateFileViewerSelecting` provides visual feedback for the MVP.
- Unified Recordings/Jobs/Settings panel — long-term direction, current TabView is a stepping stone.

**Type consistency check:**
- `KeychainRef(account:)`, `Job.apiKeyRef.account`, `KeychainStore.get(account:)` — same name throughout.
- `Job.fields: [String: String]` everywhere; coercion to numbers happens at the boundary in handlers and editor binding helpers.
- `JobShape.chatCompletionsAudio` rawValue matches `presets.json` `"shape"` strings.

**Placeholder scan:** no TBDs, no "add appropriate error handling", every code step has actual code.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-26-transcription-jobs-mvp.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, you review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
