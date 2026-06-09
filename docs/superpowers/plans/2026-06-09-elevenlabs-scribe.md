# ElevenLabs Scribe Handler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a working ElevenLabs Scribe speech-to-text transport so a Job whose Provider uses the `elevenlabs` preset transcribes `combined.flac`.

**Architecture:** A new `ElevenLabsScribeHandler` (multipart upload, mirroring `ChatCompletionsAudioHandler`) plus a shape-dispatch seam in `JobRunner`: both default senders conform to a shape-neutral `AudioJobSending` protocol, `JobRunner` holds a `[JobShape: any AudioJobSending]` map, and `run` takes a `shape:` argument resolved by `AppCoordinator` from the provider's preset.

**Tech Stack:** Swift 6.2, Foundation (`URLSession`, hand-built `multipart/form-data`), Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftPM package `AudioPipelineJobs`.

**Conventions:** Conventional-commit subjects. Per repo policy, end each commit message with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer (omitted from the one-line commands below for brevity).

**Build/test note:** Tasks 1–5 are verified with the SPM suite only:
```
swift test --disable-sandbox --package-path Packages/AudioPipeline
```
The **app target intentionally does not build between Task 1 and Task 6** — `AppCoordinator` calls `run` with the old signature until Task 6 fixes it. This mirrors the providers/jobs-split plan's documented pattern. The app target is built/tested once in Task 6 via the `xcode-build` skill.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift` (modify) | Defines `AudioJobSending`; dispatches by `JobShape`; `run(...,shape:)`. |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift` (modify) | `DefaultChatCompletionsAudioSender` conforms to `AudioJobSending`; old `ChatCompletionsAudioSending` removed. |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift` (create) | Multipart request build, response→string formatting, `DefaultElevenLabsScribeSender`. |
| `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json` (modify) | `elevenlabs.suggestedModels` → `["scribe_v2","scribe_v1"]`. |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift` (modify) | Fixtures move to `AudioJobSending` + `shape:`; new dispatch tests. |
| `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift` (create) | Request, formatting, and send tests. |
| `audio-pipeline/AppCoordinator.swift` (modify) | Resolve shape from preset, pass to `run`, handle missing preset. |

---

## Task 1: Shape-dispatch seam in `JobRunner`

Generalize the single hardcoded handler into a shape-keyed map. Keeps chat working; adds the dispatch seam and an `unsupportedShape` error. ElevenLabs is registered later (Task 4).

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift:124-136`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift`

- [ ] **Step 1: Rewrite `JobRunnerTests.swift` (fixtures + new dispatch tests)**

Replace the whole file with:

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

private actor FakeHandler: AudioJobSending {
    private(set) var lastJob: Job?
    private(set) var lastProvider: Provider?
    private(set) var lastAudio: URL?
    private(set) var lastKey: String?
    private(set) var callCount = 0
    let result: Result<String, Error>
    init(result: Result<String, Error>) { self.result = result }
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        lastJob = job; lastProvider = provider; lastAudio = audioURL; lastKey = apiKey
        callCount += 1
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

// Single-handler runner for the chat-shape behavioural tests.
private func chatRunner(keychain: any KeychainProviding, handler: any AudioJobSending) -> JobRunner {
    JobRunner(keychain: keychain, handlers: [.chatCompletionsAudio: handler])
}

@Suite struct JobRunnerBehavior {
    @Test func run_writesOutputFile_nextToRecording() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let keychain = FakeKeychain(key: "sk-x")
        let handler = FakeHandler(result: .success("transcribed text"))
        let runner = chatRunner(keychain: keychain, handler: handler)
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
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
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("new")))
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-demo (1).txt")
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "new")
    }

    @Test func run_sanitisesSlashesAndColonsInJobName() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("x")))
        var job = makeJob(providerID: provider.id)
        job.name = "Folder/With:Bad chars"
        let outURL = try await runner.run(job: job, provider: provider,
                                          shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-Folder-With-Bad chars.txt")
    }

    @Test func run_fetchesKeyForProvidersAccount() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-real")
        let handler = FakeHandler(result: .success("ok"))
        let runner = chatRunner(keychain: keychain, handler: handler)
        let provider = makeProvider()
        let job = makeJob(providerID: provider.id)
        _ = try await runner.run(job: job, provider: provider,
                                 shape: .chatCompletionsAudio, audioURL: audio)
        #expect(await handler.lastKey == "sk-real")
        #expect(await handler.lastProvider?.id == provider.id)
        #expect(await handler.lastJob?.id == job.id)
        #expect(await handler.lastAudio == audio)
    }

    @Test func run_propagatesHandlerErrors() async throws {
        struct Boom: Error {}
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .failure(Boom())))
        do {
            _ = try await runner.run(job: makeJob(providerID: provider.id),
                                     provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
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
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("hello")))
        var job = makeJob(providerID: provider.id)
        job.outputFolderPath = customFolder.path
        let outURL = try await runner.run(job: job, provider: provider,
                                          shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.deletingLastPathComponent().path == customFolder.path)
        #expect(outURL.lastPathComponent == "combined-demo.txt")
    }

    @Test func run_writesNextToAudio_whenOutputFolderPathNil() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("hi")))
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }
}

@Suite struct JobRunnerDispatch {
    @Test func run_dispatchesToHandlerForShape() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let chat = FakeHandler(result: .success("chat"))
        let scribe = FakeHandler(result: .success("scribe"))
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handlers: [.chatCompletionsAudio: chat, .elevenLabsScribe: scribe])
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .elevenLabsScribe, audioURL: audio)
        #expect(try String(contentsOf: outURL, encoding: .utf8) == "scribe")
        #expect(await scribe.callCount == 1)
        #expect(await chat.callCount == 0)
    }

    @Test func run_throwsUnsupportedShape_whenNoHandlerRegistered() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handlers: [.chatCompletionsAudio: FakeHandler(result: .success("x"))])
        do {
            _ = try await runner.run(job: makeJob(providerID: provider.id),
                                     provider: provider, shape: .geminiGenerateContent, audioURL: audio)
            Issue.record("expected throw")
        } catch JobRunner.Error.unsupportedShape(let shape) {
            #expect(shape == .geminiGenerateContent)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline 2>&1 | tail -20`
Expected: compile failure — `AudioJobSending` is undefined and `run` has no `shape:` parameter.

- [ ] **Step 3: Introduce `AudioJobSending` + dispatch in `JobRunner.swift`**

Replace the top of the file (the doc comment through the `init`) and the `run` signature. The full new `JobRunner.swift` is:

```swift
import Foundation

// Shape-neutral transport: given a Job + Provider + audio + key, returns the
// text to write to the output file. One conformer per JobShape handler.
public protocol AudioJobSending: Sendable {
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String
}

// Glue: fetch API key → dispatch to the handler for the job's shape → write
// result file next to recording. The shape is resolved by the caller from the
// provider's preset and passed in, so JobRunner stays free of PresetsStore.
public struct JobRunner: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unsupportedShape(JobShape)
    }

    private let keychain: any KeychainProviding
    private let handlers: [JobShape: any AudioJobSending]

    // Handlers wired in production. ElevenLabs is added in its own task.
    public static let defaultHandlers: [JobShape: any AudioJobSending] = [
        .chatCompletionsAudio: DefaultChatCompletionsAudioSender(),
    ]

    public init(
        keychain: any KeychainProviding,
        handlers: [JobShape: any AudioJobSending] = JobRunner.defaultHandlers
    ) {
        self.keychain = keychain
        self.handlers = handlers
    }

    @discardableResult
    public func run(job: Job, provider: Provider, shape: JobShape, audioURL: URL) async throws -> URL {
        guard let handler = handlers[shape] else {
            throw Error.unsupportedShape(shape)
        }
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
        // Ensure the target folder exists (custom folder might not). Failure here
        // bubbles via the .write() call below, which is correct: better to throw
        // than silently produce no file.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: outURL, options: .atomic)
        return outURL
    }

    // Builds "combined-<sanitised-name>.<ext>" inside `folder`; appends " (N)"
    // to the stem if the path already exists. Sanitisation replaces "/" and ":"
    // only — leaves spaces and other punctuation untouched (they're valid in
    // macOS filenames).
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

- [ ] **Step 4: Update `DefaultChatCompletionsAudioSender` conformance**

In `ChatCompletionsAudioHandler.swift`, replace the trailing protocol + struct block (lines 124–136):

```swift
// Mirror of the static `send` as a protocol, so JobRunner can be tested
// without making real network calls.
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

with (the `ChatCompletionsAudioSending` protocol is removed — `AudioJobSending` replaces it):

```swift
// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it
// (and tests can inject a fake).
public struct DefaultChatCompletionsAudioSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await ChatCompletionsAudioHandler.send(job: job, provider: provider,
                                                   audioURL: audioURL, apiKey: apiKey)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobRunner`
Expected: PASS (both `JobRunnerBehavior` and `JobRunnerDispatch` suites).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift
git commit -m "refactor(jobs): dispatch JobRunner by JobShape via AudioJobSending"
```

---

## Task 2: ElevenLabs `buildRequest` (multipart)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift`

- [ ] **Step 1: Write the failing request tests**

Create `ElevenLabsScribeHandlerTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "https://api.elevenlabs.io") -> Provider {
    Provider(name: "el", presetID: "elevenlabs",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "el-key"))
}

private func makeJob(model: String = "scribe_v2", outputExt: String = "txt",
                     fields: [String: String] = [:]) -> Job {
    Job(name: "lesson", providerID: UUID(), model: model,
        fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8], name: String = "combined.flac") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("el-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

@Suite struct ElevenLabsScribeRequest {
    @Test func buildsPOST_toSpeechToTextPath() throws {
        let audio = try writeAudio([0x01, 0x02])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    }

    @Test func usesXiApiKeyHeader_andMultipartContentType() throws {
        let audio = try writeAudio([0x01])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi-secret")
        #expect(req.value(forHTTPHeaderField: "xi-api-key") == "xi-secret")
        let ct = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary=Boundary-"))
    }

    @Test func body_containsModelIdAndFilePart() throws {
        let audio = try writeAudio([0xAA, 0xBB])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(model: "scribe_v2"), provider: makeProvider(), audioURL: audio, apiKey: "xi")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model_id\""))
        #expect(body.contains("scribe_v2"))
        #expect(body.contains("name=\"file\"; filename=\"combined.flac\""))
        #expect(body.contains("Content-Type: audio/flac"))
    }

    @Test func body_includesOptionalFields_whenSet() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["diarize": "true", "language_code": "sv", "num_speakers": "2"])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "xi")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"diarize\""))
        #expect(body.contains("name=\"language_code\""))
        #expect(body.contains("name=\"num_speakers\""))
    }

    @Test func body_omitsOptionalFields_whenEmptyOrAbsent() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["diarize": ""])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "xi")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(!body.contains("name=\"diarize\""))
        #expect(!body.contains("name=\"language_code\""))
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let audio = try writeAudio([0x01])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(), provider: makeProvider(baseURL: "https://api.elevenlabs.io/"),
            audioURL: audio, apiKey: "xi")
        #expect(req.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    }

    @Test func throws_missingModel_whenModelEmpty() throws {
        let audio = try writeAudio([0x01])
        do {
            _ = try ElevenLabsScribeHandler.buildRequest(
                job: makeJob(model: ""), provider: makeProvider(), audioURL: audio, apiKey: "xi")
            Issue.record("expected missingModel")
        } catch ElevenLabsScribeHandler.BuildError.missingModel {
            // expected
        }
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try ElevenLabsScribeHandler.buildRequest(
                job: makeJob(), provider: makeProvider(), audioURL: missing, apiKey: "xi")
            Issue.record("expected audioReadFailed")
        } catch ElevenLabsScribeHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ElevenLabsScribeRequest 2>&1 | tail -20`
Expected: compile failure — `ElevenLabsScribeHandler` is undefined.

- [ ] **Step 3: Create `ElevenLabsScribeHandler.swift` with `buildRequest`**

```swift
import Foundation

// HTTP handler for the ElevenLabs Speech-to-Text endpoint (the
// "elevenLabsScribe" shape).
//
// Wire shape:
//   POST {baseURL}/v1/speech-to-text
//   xi-api-key: <key>
//   Content-Type: multipart/form-data; boundary=Boundary-<uuid>
//   parts: model_id (= job.model), file (the audio), plus any of
//          language_code / diarize / num_speakers / timestamps_granularity /
//          tag_audio_events present in job.fields.
public enum ElevenLabsScribeHandler {
    public enum BuildError: Error, Equatable {
        case missingModel
        case invalidBaseURL
        case audioReadFailed
    }

    // Optional form fields copied straight from job.fields when present & non-empty.
    static let optionalFields = [
        "language_code", "diarize", "num_speakers",
        "timestamps_granularity", "tag_audio_events",
    ]

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let endpoint = URL(string: trimmedBase + "/v1/speech-to-text") else {
            throw BuildError.invalidBaseURL
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("model_id", job.model)
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                appendField(key, value)
            }
        }

        // File part last.
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/flac\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }
}

// File-local: append a String's UTF-8 bytes to Data (Foundation has no helper).
private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ElevenLabsScribeRequest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift
git commit -m "feat(jobs): ElevenLabs Scribe multipart buildRequest"
```

---

## Task 3: Response formatting (labelled text / json)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift`

- [ ] **Step 1: Add the failing formatting tests**

Append this suite to `ElevenLabsScribeHandlerTests.swift`:

```swift
@Suite struct ElevenLabsScribeFormat {
    @Test func diarized_rendersSpeakerLabelsInFirstSeenOrder() throws {
        let json = """
        {"text":"Hello there hi",
         "words":[
           {"text":"Hello","type":"word","speaker_id":"speaker_0"},
           {"text":" ","type":"spacing","speaker_id":"speaker_0"},
           {"text":"there","type":"word","speaker_id":"speaker_0"},
           {"text":"hi","type":"word","speaker_id":"speaker_1"}]}
        """
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: Hello there\nSpeaker 2: hi")
    }

    @Test func wordsWithoutSpeakerIds_returnPlainText() throws {
        let json = #"{"text":"plain transcript","words":[{"text":"plain"},{"text":" transcript"}]}"#
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "plain transcript")
    }

    @Test func noWordsArray_returnsPlainText() throws {
        let json = #"{"text":"just text"}"#
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "just text")
    }

    @Test func jsonOutput_returnsPrettyRawResponse() throws {
        let json = #"{"text":"hi","language_code":"en","words":[{"text":"hi","speaker_id":"speaker_0"}]}"#
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "json")
        #expect(out.contains("\"language_code\""))   // snake_case preserved
        #expect(out.contains("\"speaker_id\""))
        #expect(out.contains("\n"))                   // pretty-printed
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try ElevenLabsScribeHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected malformedResponse")
        } catch ElevenLabsScribeHandler.SendError.malformedResponse {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ElevenLabsScribeFormat 2>&1 | tail -20`
Expected: compile failure — `SendError` and `format(data:outputExt:)` are undefined.

- [ ] **Step 3: Add `SendError`, `format`, and `Response` to `ElevenLabsScribeHandler.swift`**

Insert the following members inside the `ElevenLabsScribeHandler` enum, after the `buildRequest` function's closing brace (before the enum's closing brace):

```swift
    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
    }

    // Maps the JSON response to the string JobRunner writes. "json" → the raw
    // response, pretty-printed (snake_case preserved); anything else →
    // speaker-labelled transcript, falling back to plain text when the response
    // carries no speaker ids.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let resp = try? decoder.decode(Response.self, from: data) else {
            throw SendError.malformedResponse
        }
        return resp.labelledTranscript()
    }

    struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            let speakerId: String?
        }
        let text: String
        let words: [Word]?

        // Groups consecutive words by speaker; assigns "Speaker N" in first-seen
        // order. Words with no speaker id attach to the current run. Returns the
        // plain transcript when no word carries a speaker id.
        func labelledTranscript() -> String {
            guard let words, words.contains(where: { $0.speakerId != nil }) else {
                return text
            }
            var runs: [(speaker: String, text: String)] = []
            for w in words {
                if let speaker = w.speakerId, runs.last?.speaker != speaker {
                    runs.append((speaker, w.text))
                } else if runs.isEmpty {
                    runs.append((w.speakerId ?? "", w.text))
                } else {
                    runs[runs.count - 1].text += w.text
                }
            }
            var order: [String: Int] = [:]
            var next = 1
            let lines = runs.map { run -> String in
                let n: Int
                if let existing = order[run.speaker] {
                    n = existing
                } else {
                    n = next
                    order[run.speaker] = next
                    next += 1
                }
                return "Speaker \(n): \(run.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return lines.joined(separator: "\n")
        }
    }
```

- [ ] **Step 4: Run to verify the formatting tests pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ElevenLabsScribeFormat`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift
git commit -m "feat(jobs): ElevenLabs Scribe response formatting (labelled text / json)"
```

---

## Task 4: `send` + register the handler in `JobRunner`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift` (the `defaultHandlers` map)
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift`

- [ ] **Step 1: Add the failing send tests**

Append to `ElevenLabsScribeHandlerTests.swift` (its own URLProtocol stub avoids shared static state with the chat-handler tests):

```swift
// URLProtocol stub local to the ElevenLabs send tests.
final class ScribeStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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

private func scribeStubSession(status: Int, body: Data) -> URLSession {
    ScribeStubProtocol.response = (status, body)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ScribeStubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct ElevenLabsScribeSend {
    @Test func send_returnsLabelledTranscript_onSuccess() async throws {
        let json = #"{"text":"hi","words":[{"text":"hi","speaker_id":"speaker_0"}]}"#
        let session = scribeStubSession(status: 200, body: Data(json.utf8))
        let audio = try writeAudio([0x01])
        let text = try await ElevenLabsScribeHandler.send(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi", session: session)
        #expect(text == "Speaker 1: hi")
    }

    @Test func send_throws_onNon200() async throws {
        let session = scribeStubSession(status: 401, body: Data(#"{"detail":"unauthorized"}"#.utf8))
        let audio = try writeAudio([0x01])
        do {
            _ = try await ElevenLabsScribeHandler.send(
                job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi", session: session)
            Issue.record("expected throw")
        } catch ElevenLabsScribeHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ElevenLabsScribeSend 2>&1 | tail -20`
Expected: compile failure — `send` and `DefaultElevenLabsScribeSender` are undefined.

- [ ] **Step 3: Add `send` + `DefaultElevenLabsScribeSender`**

Insert `send` inside the `ElevenLabsScribeHandler` enum, after `format(...)`:

```swift
    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let request = try buildRequest(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try format(data: data, outputExt: job.outputExt)
    }
```

Then add the default sender after the `private extension Data` block at the bottom of the file:

```swift
// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it.
public struct DefaultElevenLabsScribeSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await ElevenLabsScribeHandler.send(job: job, provider: provider,
                                               audioURL: audioURL, apiKey: apiKey)
    }
}
```

- [ ] **Step 4: Register the handler in `JobRunner.defaultHandlers`**

In `JobRunner.swift`, replace the `defaultHandlers` map:

```swift
    public static let defaultHandlers: [JobShape: any AudioJobSending] = [
        .chatCompletionsAudio: DefaultChatCompletionsAudioSender(),
    ]
```

with:

```swift
    public static let defaultHandlers: [JobShape: any AudioJobSending] = [
        .chatCompletionsAudio: DefaultChatCompletionsAudioSender(),
        .elevenLabsScribe: DefaultElevenLabsScribeSender(),
    ]
```

- [ ] **Step 5: Run the full SPM suite to verify everything passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline 2>&1 | tail -10`
Expected: PASS — all suites, including the new ElevenLabs suites.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift
git commit -m "feat(jobs): ElevenLabs Scribe send + register in JobRunner dispatch"
```

---

## Task 5: Preset — `scribe_v2`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json:24-27`

- [ ] **Step 1: Update the `elevenlabs` preset's suggested models**

Replace the `elevenlabs` entry:

```json
  {"id":"elevenlabs","displayName":"ElevenLabs Scribe","shape":"elevenLabsScribe",
   "baseURL":"https://api.elevenlabs.io","suggestedModels":["scribe_v1","scribe_v1_experimental"],
   "defaults":{"diarize":"true"},
   "docsURL":"https://elevenlabs.io/docs/api-reference/speech-to-text"},
```

with:

```json
  {"id":"elevenlabs","displayName":"ElevenLabs Scribe","shape":"elevenLabsScribe",
   "baseURL":"https://api.elevenlabs.io","suggestedModels":["scribe_v2","scribe_v1"],
   "defaults":{"diarize":"true"},
   "docsURL":"https://elevenlabs.io/docs/api-reference/speech-to-text"},
```

- [ ] **Step 2: Verify the preset library still loads (decodes) cleanly**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter Preset 2>&1 | tail -10`
Expected: PASS (or "no tests matched" — in that case run the full suite below). Either way, run the full suite to confirm nothing decodes-broke:
`swift test --disable-sandbox --package-path Packages/AudioPipeline 2>&1 | tail -5` → PASS.

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json
git commit -m "feat(jobs): default ElevenLabs preset to scribe_v2"
```

---

## Task 6: Wire `AppCoordinator` + verify the app target

Resolve the job's shape from the provider's preset and pass it to `run`. This is the change that makes the app target compile again.

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift:216-249` (the `runJob` method) and `:277-280` (`JobRunError`)

- [ ] **Step 1: Add a `presetMissing` error case**

In `AppCoordinator.swift`, replace:

```swift
    enum JobRunError: Error {
        case combinedFlacMissing
        case providerMissing
    }
```

with:

```swift
    enum JobRunError: Error {
        case combinedFlacMissing
        case providerMissing
        case presetMissing
    }
```

- [ ] **Step 2: Resolve the shape and pass it to `run`**

In `runJob`, the current provider guard is:

```swift
        guard let providerID = job.providerID,
              let provider = providers.provider(id: providerID) else {
            await self.flashActivity("Failed: '\(job.name)' — provider missing")
            return .failure(JobRunError.providerMissing)
        }
```

Immediately after that block, insert:

```swift
        guard let shape = presets.preset(id: provider.presetID)?.shape else {
            await self.flashActivity("Failed: '\(job.name)' — provider preset unknown")
            return .failure(JobRunError.presetMissing)
        }
```

Then change the run call from:

```swift
        let runner = JobRunner(keychain: keychain)
        do {
            let out = try await runner.run(job: job, provider: provider, audioURL: target)
```

to:

```swift
        let runner = JobRunner(keychain: keychain)
        do {
            let out = try await runner.run(job: job, provider: provider, shape: shape, audioURL: target)
```

- [ ] **Step 3: Build + test the app target via the xcode-build skill**

Use the `xcode-build` skill (the Hammerspoon daemon — `xcodebuild` self-refuses inside the sandbox). Build the scheme and run the app-hosted suite:

```
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test
```

Expected: build succeeds (app target compiles with the new `run` signature) and the app-hosted XCTest target passes. If the daemon path is unavailable, at minimum confirm a Debug build:
`xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build` (run outside the sandbox).

- [ ] **Step 4: Run the full SPM suite once more**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "feat(jobs): resolve job shape from preset in AppCoordinator.runJob"
```

---

## Done

A Job whose Provider uses the `elevenlabs` preset now uploads `combined.flac` to ElevenLabs Scribe (`scribe_v2` by default), writes a speaker-labelled transcript (or raw JSON when `outputExt == "json"`), and `JobRunner` routes every shape through `AudioJobSending` — with `transcriptionMultipart`/`geminiGenerateContent` failing loudly as `unsupportedShape` until they get handlers of their own.

**Manual smoke test (optional, needs a real key):** add an ElevenLabs provider in the app, store an `xi-api-key`, create a Job against it with `diarize` on, run it on a recording, and confirm a `combined-<job>.txt` with `Speaker N:` lines lands next to `combined.flac`.
