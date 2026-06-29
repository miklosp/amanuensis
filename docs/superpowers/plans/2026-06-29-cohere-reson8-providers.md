# Cohere and Reson8 Transcription Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cohere (fix its broken speculative preset) and Reson8 as working speech-to-text providers in the Jobs layer.

**Architecture:** Cohere gets a new `cohereTranscribe` JobShape whose handler reuses the existing `TranscriptionMultipartHandler` via a new `path:` parameter (Cohere is wire-identical to the OpenAI multipart shape except for the `/v2` path and a required `language`). Reson8 gets a new `reson8Prerecorded` JobShape with its own handler modeled on `DeepgramListenHandler` (raw audio body + query-param options). A new `JobShape.requiresModel` flag lets the Job editor hide the Model field for Reson8, which needs no model.

**Tech Stack:** Swift 6.2, Swift Testing (`@Suite`/`@Test`), local SPM package `Packages/AudioPipeline` (module `AudioPipelineJobs`), SwiftUI app target `Amanuensis`.

## Global Constraints

- Default actor isolation is `MainActor`; the new handlers mirror the existing `enum`-with-`static`-funcs handlers (`DeepgramListenHandler`, `TranscriptionMultipartHandler`) exactly — do not add `@MainActor`/actor annotations they don't have.
- SPM tests run **in-sandbox** with: `swift test --disable-sandbox --package-path Packages/AudioPipeline` (the `--disable-sandbox` flag is required — see `CLAUDE.local.md`).
- App-target build (sandbox) goes through the daemon helper: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`. `/usr/bin/xcodebuild` self-refuses in-sandbox.
- One JobShape per wire-level handler; presets are data in `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`.
- Switches over `JobShape` (`baseURLPathHint`, `fields`, `requiresModel`) are exhaustive — the compiler forces every case to be handled when a new case is added.
- Commit messages: Conventional Commits, with trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Work happens on branch `feat/cohere-reson8-providers` (already created; the design spec is already committed there).

---

### Task 1: Cohere — `cohereTranscribe` shape, path-param handler reuse, preset fix

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift` (add enum case + `baseURLPathHint`)
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift` (add `.cohereTranscribe` fields)
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/TranscriptionMultipartHandler.swift` (add `path:` param to `buildRequest`/`send`)
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/CohereTranscribeHandler.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift` (register handler)
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json` (cohere entry)
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/CohereTranscribeHandlerTests.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift` (assert cohere shape)

**Interfaces:**
- Produces: `JobShape.cohereTranscribe`; `TranscriptionMultipartHandler.buildRequest(job:provider:audioURL:apiKey:path:)` and `.send(...path:)` with `path` defaulting to `"/v1/audio/transcriptions"`; `struct DefaultCohereSender: AudioJobSending` with `static let transcriptionsPath = "/v2/audio/transcriptions"`.
- Consumes: existing `TranscriptionMultipartHandler` transport (compression, `{"text"}` parser, 600 s timeout), `AudioJobSending`, `JobRunner.defaultHandlers`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/CohereTranscribeHandlerTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func writeAudio(_ bytes: [UInt8]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cohere-\(UUID().uuidString).flac")
    try Data(bytes).write(to: url)
    return url
}

@Suite struct CohereTranscribeShape {
    @Test func shape_hasV2TranscriptionsPathHint() {
        #expect(JobShape.cohereTranscribe.baseURLPathHint == "/v2/audio/transcriptions")
    }

    @Test func fields_languageRequired_temperatureOptional_noPrompt() {
        let byKey = Dictionary(uniqueKeysWithValues:
            JobShape.cohereTranscribe.fields.map { ($0.key, $0) })
        #expect(byKey["language"]?.required == true)
        #expect(byKey["temperature"]?.required == false)
        #expect(byKey["prompt"] == nil)
    }
}

@Suite struct CohereTranscribeRequest {
    private func makeProvider() -> Provider {
        Provider(name: "c", presetID: "cohere", baseURL: "https://api.cohere.com",
                 apiKeyRef: KeychainRef(account: "cohere-key"))
    }

    @Test func buildRequest_targetsV2Path_andBearerAuth() throws {
        let job = Job(name: "t", providerID: UUID(), model: "cohere-transcribe-03-2026",
                      fields: ["language": "en"], outputExt: "txt")
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: try writeAudio([0x01]),
            apiKey: "k", path: DefaultCohereSender.transcriptionsPath)
        #expect(req.url?.absoluteString == "https://api.cohere.com/v2/audio/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func buildRequest_defaultsToV1_whenPathOmitted() throws {
        // Regression: existing multipart callers (OpenAI/Groq/Mistral) unaffected.
        let provider = Provider(name: "o", presetID: "openai-whisper",
                                baseURL: "https://api.openai.com",
                                apiKeyRef: KeychainRef(account: "k"))
        let job = Job(name: "t", providerID: UUID(), model: "whisper-1",
                      fields: [:], outputExt: "txt")
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: job, provider: provider, audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
    }
}

@Suite struct CohereTranscribeDispatch {
    @Test func jobRunner_registersCohereHandler() {
        #expect(JobRunner.defaultHandlers[.cohereTranscribe] != nil)
    }
}
```

Add two assertions to `PresetsStoreTests.swift` inside the existing `PresetsStoreBehavior` suite (after the `loadsAllBundledPresets` test):

```swift
    @Test func cohere_usesCohereTranscribeShape_andDropsPromptOverrides() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "cohere")
        #expect(p?.shape == .cohereTranscribe)
        #expect(p?.fieldLabels?["prompt"] == nil)
        #expect(p?.suggestedModels == ["cohere-transcribe-03-2026"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter CohereTranscribe`
Expected: FAILS TO COMPILE — `type 'JobShape' has no member 'cohereTranscribe'`, `DefaultCohereSender` undefined, `path:` argument unknown. (Compile failure is the red state in Swift.)

- [ ] **Step 3: Add the `cohereTranscribe` enum case and path hint**

In `JobShape.swift`, add the case after `deepgramListen` (line 10):

```swift
    case deepgramListen             // Deepgram /v1/listen, raw body + query-param options
    case cohereTranscribe           // Cohere /v2/audio/transcriptions (multipart, v2 path)
```

In the `baseURLPathHint` switch, add (after the `deepgramListen` case):

```swift
        case .deepgramListen:        return "/v1/listen"
        case .cohereTranscribe:      return "/v2/audio/transcriptions"
```

- [ ] **Step 4: Add the `.cohereTranscribe` field spec**

In `FieldSpec.swift`, add a case to the `fields` switch (after the `.deepgramListen` case, before the closing `}`):

```swift
        case .cohereTranscribe:
            return [
                FieldSpec(key: "language", label: "Language", kind: .language, required: true,
                          help: "ISO-639-1; required by Cohere"),
                FieldSpec(key: "temperature", label: "Temperature", kind: .number, required: false),
            ]
```

- [ ] **Step 5: Add the `path:` parameter to `TranscriptionMultipartHandler`**

In `TranscriptionMultipartHandler.swift`, change `buildRequest`'s signature (line 24) and its endpoint line (line 28):

```swift
    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String,
                                    path: String = "/v1/audio/transcriptions") throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let endpoint = URL(string: trimmedBase + path) else {
            throw BuildError.invalidBaseURL
        }
```

Change the public `send` (lines 154-163) to accept and forward `path`:

```swift
    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = TranscriptionMultipartHandler.defaultSession,
        path: String = "/v1/audio/transcriptions"
    ) async throws -> String {
        try await send(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey,
                       session: session, maxBytes: maxUploadBytes, compress: defaultCompress, path: path)
    }
```

Change the internal `send` (lines 167-187) to accept `path` and forward it to `buildRequest`:

```swift
    static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession,
        maxBytes: Int,
        compress: Compress,
        path: String = "/v1/audio/transcriptions"
    ) async throws -> String {
        let prepared = try await prepareUpload(audioURL: audioURL, maxBytes: maxBytes, compress: compress)
        defer { if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) } }
        let request = try buildRequest(job: job, provider: provider, audioURL: prepared.url, apiKey: apiKey, path: path)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse(body: data)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try parseResponse(data: data, responseFormat: job.fields["response_format"])
    }
```

- [ ] **Step 6: Create the Cohere sender**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/CohereTranscribeHandler.swift`:

```swift
import Foundation

// Cohere audio transcription (the "cohereTranscribe" shape). Wire-identical to
// the OpenAI multipart shape except the endpoint path is /v2 and `language` is
// required, so this reuses TranscriptionMultipartHandler entirely, passing
// Cohere's path. Required-language is enforced at the Job-editor Save gate via
// the FieldSpec, matching how the multipart handler validates (it doesn't).
//
//   POST {baseURL}/v2/audio/transcriptions
//   Authorization: Bearer <key>
//   multipart: model, language (required), temperature?, file
//   response: {"text": "..."}
public struct DefaultCohereSender: AudioJobSending {
    public static let transcriptionsPath = "/v2/audio/transcriptions"

    public init() {}

    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await TranscriptionMultipartHandler.send(
            job: job, provider: provider, audioURL: audioURL, apiKey: apiKey,
            path: Self.transcriptionsPath)
    }
}
```

- [ ] **Step 7: Register the handler in `JobRunner`**

In `JobRunner.swift`, add to `defaultHandlers` (after the `.deepgramListen` line, line 21):

```swift
        .deepgramListen: DefaultDeepgramListenSender(),
        .cohereTranscribe: DefaultCohereSender(),
```

- [ ] **Step 8: Fix the Cohere preset**

In `presets.json`, replace the existing cohere entry (lines 33-38) with:

```json
  {"id":"cohere","displayName":"Cohere","shape":"cohereTranscribe",
   "baseURL":"https://api.cohere.com","suggestedModels":["cohere-transcribe-03-2026"],"defaults":{},
   "docsURL":"https://docs.cohere.com/reference/create-audio-transcription","defaultOutputExt":"txt"},
```

(Removes `shape: transcriptionMultipart` → `cohereTranscribe`, and drops the now-dead `prompt` `fieldLabels`/`fieldHints`/`fieldHelp` — `cohereTranscribe` has no prompt field.)

- [ ] **Step 9: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter "CohereTranscribe|PresetsStoreBehavior"`
Expected: PASS — all `CohereTranscribe*` suites and the full `PresetsStoreBehavior` suite green (including the unchanged `loadsAllBundledPresets` count of 14 and the new `cohere_usesCohereTranscribeShape_andDropsPromptOverrides`).

- [ ] **Step 10: Run the whole SPM suite (regression check)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — confirms the `path:` change didn't break the existing `TranscriptionMultipart*` suites (which call `buildRequest`/`send` without `path` and rely on the `/v1` default).

- [ ] **Step 11: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/TranscriptionMultipartHandler.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/CohereTranscribeHandler.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/CohereTranscribeHandlerTests.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(jobs): fix Cohere provider with /v2 transcribe path

Cohere was added speculatively on the transcriptionMultipart shape, which
hardcodes /v1/audio/transcriptions; Cohere's endpoint is /v2. Add a
cohereTranscribe shape whose handler reuses TranscriptionMultipartHandler via a
new path parameter, enforce required language, and drop the dead prompt field.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Reson8 — `reson8Prerecorded` shape, handler, preset

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift` (add enum case + `baseURLPathHint`)
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift` (add `.reson8Prerecorded` fields)
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8PrerecordedHandler.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift` (register handler)
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json` (add reson8 entry)
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8PrerecordedHandlerTests.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift` (bump count to 15, add reson8)

**Interfaces:**
- Produces: `JobShape.reson8Prerecorded`; `enum Reson8PrerecordedHandler` with `buildRequest(job:provider:audioURL:apiKey:) -> URLRequest`, `format(data:outputExt:) -> String`, `send(job:provider:audioURL:apiKey:session:) -> String`, `BuildError`/`SendError`, `defaultSession`, `requestTimeout`; `struct DefaultReson8PrerecordedSender: AudioJobSending`.
- Consumes: `AudioJobSending`, `JobRunner.defaultHandlers`, the existing package-internal `describeResponseBody(_:)` helper (already used by `DeepgramListenHandler`/`TranscriptionMultipartHandler` error descriptions).

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8PrerecordedHandlerTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "https://api.reson8.dev") -> Provider {
    Provider(name: "r8", presetID: "reson8",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "r8-key"))
}

private func makeJob(model: String = "", outputExt: String = "txt",
                     fields: [String: String] = [:]) -> Job {
    Job(name: "lesson", providerID: UUID(), model: model,
        fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8], name: String = "combined.flac") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("r8-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

@Suite struct Reson8Request {
    @Test func buildsPOST_toPrerecordedPath() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/speech-to-text/prerecorded")
    }

    @Test func usesApiKeyAuthHeader_andOctetStreamContentType() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "secret")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "ApiKey secret")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test func body_isRawAudioBytes() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0xAA, 0xBB]), apiKey: "k")
        #expect(req.httpBody == Data([0xAA, 0xBB]))
    }

    @Test func emptyModel_isAllowed_noModelQuery() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(model: ""), provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        let query = req.url?.query ?? ""
        #expect(!query.contains("model="))
        #expect(!query.contains("custom_model_id="))
    }

    @Test func query_includesOptionalFields_whenSet() throws {
        let job = makeJob(fields: ["language": "en", "diarize": "true", "max_speakers": "3"])
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        let query = try #require(req.url?.query)
        #expect(query.contains("language=en"))
        #expect(query.contains("diarize=true"))
        #expect(query.contains("max_speakers=3"))
    }

    @Test func query_omitsOptionalFields_whenEmptyOrAbsent() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(fields: ["language": ""]), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        let query = req.url?.query ?? ""
        #expect(!query.contains("language="))
        #expect(!query.contains("diarize="))
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(baseURL: "https://api.reson8.dev/"),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.path == "/v1/speech-to-text/prerecorded")
        #expect(req.url?.absoluteString.contains("//v1/speech-to-text") == false)
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try Reson8PrerecordedHandler.buildRequest(
                job: makeJob(), provider: makeProvider(), audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch Reson8PrerecordedHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}

@Suite struct Reson8Format {
    @Test func plainText_returnedForTextOutput() throws {
        let json = #"{"text":"the patient presented with chest pain"}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "the patient presented with chest pain")
    }

    @Test func diarized_rendersSpeakerLabelsInFirstSeenOrder() throws {
        let json = #"{"text":"where does it hurt my chest","segments":[{"text":"where does it hurt","speaker_id":0},{"text":"my chest","speaker_id":1}]}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: where does it hurt\nSpeaker 2: my chest")
    }

    @Test func diarized_mergesConsecutiveSameSpeakerSegments() throws {
        let json = #"{"text":"a b c","segments":[{"text":"a","speaker_id":2},{"text":"b","speaker_id":2},{"text":"c","speaker_id":5}]}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: a b\nSpeaker 2: c")
    }

    @Test func segmentsWithoutSpeaker_returnFlatText() throws {
        let json = #"{"text":"flat text here","segments":[{"text":"flat text here"}]}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "flat text here")
    }

    @Test func jsonOutput_returnsPrettyRawResponse() throws {
        let json = #"{"text":"hi"}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "json")
        #expect(out.contains("\"text\""))
        #expect(out.contains("\n"))   // pretty-printed
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try Reson8PrerecordedHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected malformedResponse")
        } catch Reson8PrerecordedHandler.SendError.malformedResponse {
            // expected
        }
    }
}

// URLProtocol stub local to the Reson8 send tests.
private final class Reson8StubProtocol: URLProtocol, @unchecked Sendable {
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

private func reson8StubSession(status: Int, body: Data) -> URLSession {
    Reson8StubProtocol.response = (status, body)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Reson8StubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct Reson8Send {
    @Test func send_returnsTranscript_onSuccess() async throws {
        let session = reson8StubSession(status: 200, body: Data(#"{"text":"hi there"}"#.utf8))
        let text = try await Reson8PrerecordedHandler.send(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]),
            apiKey: "k", session: session)
        #expect(text == "hi there")
    }

    @Test func send_throws_onNon200() async throws {
        let session = reson8StubSession(status: 401, body: Data(#"{"err":"unauthorized"}"#.utf8))
        do {
            _ = try await Reson8PrerecordedHandler.send(
                job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]),
                apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch Reson8PrerecordedHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }
}

@Suite struct Reson8ErrorDescription {
    @Test func httpError_describesStatusAndBody() {
        let e = Reson8PrerecordedHandler.SendError.httpError(
            status: 400, body: Data(#"{"err":"bad request"}"#.utf8))
        #expect(e.localizedDescription.contains("400"))
        #expect(e.localizedDescription.contains("bad request"))
    }
}

@Suite struct Reson8Shape {
    @Test func shape_hasPrerecordedPathHint() {
        #expect(JobShape.reson8Prerecorded.baseURLPathHint == "/v1/speech-to-text/prerecorded")
    }

    @Test func shape_exposesLanguageDiarizeMaxSpeakers() {
        let keys = Set(JobShape.reson8Prerecorded.fields.map(\.key))
        #expect(keys == ["language", "diarize", "max_speakers"])
    }
}

@Suite struct Reson8Dispatch {
    @Test func jobRunner_registersReson8Handler() {
        #expect(JobRunner.defaultHandlers[.reson8Prerecorded] != nil)
    }
}
```

In `PresetsStoreTests.swift`, update `loadsAllBundledPresets`: change the count and add the id assertion:

```swift
        #expect(ids.contains("gemini-openai"))
        #expect(ids.contains("reson8"))
        #expect(store.all.count == 15)
```

And add a reson8 preset test inside `PresetsStoreBehavior`:

```swift
    @Test func reson8_presetExists() throws {
        let store = try PresetsStore.loadBundled()
        let p = store.preset(id: "reson8")
        #expect(p?.shape == .reson8Prerecorded)
        #expect(p?.baseURL == "https://api.reson8.dev")
        #expect(p?.suggestedModels.isEmpty == true)
        #expect(p?.defaultOutputExt == "txt")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter "Reson8|PresetsStoreBehavior"`
Expected: FAILS TO COMPILE — `JobShape` has no member `reson8Prerecorded`, `Reson8PrerecordedHandler` undefined. (Red.)

- [ ] **Step 3: Add the `reson8Prerecorded` enum case and path hint**

In `JobShape.swift`, add the case after `cohereTranscribe`:

```swift
    case cohereTranscribe           // Cohere /v2/audio/transcriptions (multipart, v2 path)
    case reson8Prerecorded          // Reson8 prerecorded STT: raw body + query-param options
```

In the `baseURLPathHint` switch, add:

```swift
        case .cohereTranscribe:      return "/v2/audio/transcriptions"
        case .reson8Prerecorded:     return "/v1/speech-to-text/prerecorded"
```

- [ ] **Step 4: Add the `.reson8Prerecorded` field spec**

In `FieldSpec.swift`, add a case to the `fields` switch:

```swift
        case .reson8Prerecorded:
            return [
                FieldSpec(key: "language", label: "Language", kind: .language, required: false,
                          help: "ISO-639-1; omit to auto-detect"),
                FieldSpec(key: "diarize", label: "Speaker diarization", kind: .checkbox, required: false),
                FieldSpec(key: "max_speakers", label: "Max speakers", kind: .number, required: false,
                          help: "Upper bound for diarization"),
            ]
```

- [ ] **Step 5: Create the Reson8 handler**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8PrerecordedHandler.swift`:

```swift
import Foundation

// HTTP handler for Reson8's prerecorded speech-to-text endpoint (the
// "reson8Prerecorded" shape).
//
// Wire shape:
//   POST {baseURL}/v1/speech-to-text/prerecorded?<options>
//   Authorization: ApiKey <key>
//   Content-Type: application/octet-stream
//   body: the raw audio bytes (Reson8 takes raw audio, not multipart)
//
// Options are URL query parameters from job.fields: language / diarize /
// max_speakers, passed through when present & non-empty. Reson8 has no required
// model — a server-side default is used — so none is sent (custom_model_id is
// not exposed). No upload-size cap is documented, so audio is sent untouched
// (unlike the multipart handler's 24 MB compression path).
public enum Reson8PrerecordedHandler {
    public enum BuildError: Error, Equatable {
        case invalidBaseURL
        case audioReadFailed
    }

    // Pass-through query params copied from job.fields when present & non-empty.
    private static let optionalFields = ["language", "diarize", "max_speakers"]

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard var components = URLComponents(string: trimmedBase + "/v1/speech-to-text/prerecorded") else {
            throw BuildError.invalidBaseURL
        }

        var items: [URLQueryItem] = []
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                items.append(URLQueryItem(name: key, value: value))
            }
        }
        if !items.isEmpty { components.queryItems = items }
        guard let endpoint = components.url else { throw BuildError.invalidBaseURL }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = audioData
        return req
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse(body: Data)
    }

    // "json" → the raw response pretty-printed (keys sorted for stable output);
    // otherwise the top-level transcript, or — when diarization produced
    // speaker-labelled segments — "Speaker N: …" lines (first-seen speaker
    // order, consecutive same-speaker segments merged). Any drift in the
    // optional segments array degrades to the flat transcript rather than failing.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse(body: data)
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SendError.malformedResponse(body: data)
        }
        return resp.labelledTranscript()
    }

    // Reson8 holds the connection while transcribing pre-recorded audio, so the
    // 60s URLSession default can abort longer recordings — wait generously,
    // matching the other synchronous handlers.
    static let requestTimeout: TimeInterval = 600

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = Reson8PrerecordedHandler.defaultSession
    ) async throws -> String {
        let request = try buildRequest(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse(body: data)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try format(data: data, outputExt: job.outputExt)
    }

    struct Response: Decodable {
        struct Segment: Decodable {
            let text: String
            let speakerID: Int?
            enum CodingKeys: String, CodingKey {
                case text
                case speakerID = "speaker_id"
            }
        }
        let text: String
        let segments: [Segment]?

        // Groups consecutive same-speaker segments into "Speaker N: …" lines
        // (first-seen order). Falls back to the flat top-level transcript when
        // diarization is off or no segment carries a speaker_id.
        func labelledTranscript() -> String {
            guard let segments, segments.contains(where: { $0.speakerID != nil }) else {
                return text
            }
            var runs: [(speaker: Int, parts: [String])] = []
            for seg in segments {
                guard let sid = seg.speakerID else {
                    // Segment with no speaker — attach to the current run if any.
                    if !runs.isEmpty { runs[runs.count - 1].parts.append(seg.text) }
                    continue
                }
                if runs.last?.speaker != sid {
                    runs.append((sid, [seg.text]))
                } else {
                    runs[runs.count - 1].parts.append(seg.text)
                }
            }
            var order: [Int: Int] = [:]
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
                return "Speaker \(n): \(run.parts.joined(separator: " "))"
            }
            return lines.joined(separator: "\n")
        }
    }
}

// Full-detail messages for the in-app log; `localizedDescription` resolves to these.
extension Reson8PrerecordedHandler.SendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .httpError(status, body):
            return "Reson8 HTTP \(status): \(describeResponseBody(body))"
        case let .malformedResponse(body):
            return "Reson8: could not decode the response: \(describeResponseBody(body))"
        }
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it.
public struct DefaultReson8PrerecordedSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await Reson8PrerecordedHandler.send(job: job, provider: provider,
                                                audioURL: audioURL, apiKey: apiKey)
    }
}
```

- [ ] **Step 6: Register the handler in `JobRunner`**

In `JobRunner.swift`, add to `defaultHandlers`:

```swift
        .cohereTranscribe: DefaultCohereSender(),
        .reson8Prerecorded: DefaultReson8PrerecordedSender(),
```

- [ ] **Step 7: Add the Reson8 preset**

In `presets.json`, add a new entry as the last array element (after the deepgram entry; change its closing `}` to `},` and append):

```json
  {"id":"deepgram","displayName":"Deepgram","shape":"deepgramListen",
   "baseURL":"https://api.deepgram.com","suggestedModels":["nova-3","nova-2"],
   "defaults":{"smart_format":"true"},"defaultOutputExt":"json",
   "docsURL":"https://developers.deepgram.com/docs/pre-recorded-audio",
   "fieldHelp":{"keyterm":"Keyterm Prompting (Nova-3): biases toward names/jargon — up to ~100 terms, 500 tokens/request, comma-separated. Not free-text instructions. (Nova-2 and earlier use keywords instead.)"}},
  {"id":"reson8","displayName":"Reson8","shape":"reson8Prerecorded",
   "baseURL":"https://api.reson8.dev","suggestedModels":[],"defaults":{},
   "docsURL":"https://docs.reson8.dev/documentation/speech-to-text/prerecorded/","defaultOutputExt":"txt"}
]
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter "Reson8|PresetsStoreBehavior"`
Expected: PASS — all `Reson8*` suites and `PresetsStoreBehavior` (count now 15) green.

- [ ] **Step 9: Run the whole SPM suite (regression check)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — entire package suite green.

- [ ] **Step 10: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8PrerecordedHandler.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8PrerecordedHandlerTests.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(jobs): add Reson8 prerecorded transcription provider

Raw-audio-body + query-param shape (ApiKey auth, /v1/speech-to-text/prerecorded),
modeled on the Deepgram handler. Top-level transcript, with Speaker N: lines when
diarization returns speaker-labelled segments. No required model.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Job editor — hide the Model field for shapes that need no model

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift` (add `requiresModel`)
- Modify: `Amanuensis/UI/Jobs/JobEditorView.swift` (conditional Model row + `canSave`)
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift`

**Interfaces:**
- Consumes: `JobShape.reson8Prerecorded` (Task 2), `Preset.shape`, `PresetsStore`.
- Produces: `JobShape.requiresModel: Bool`.

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift`:

```swift
import Testing
@testable import AudioPipelineJobs

@Suite struct JobShapeRequiresModel {
    @Test func onlyReson8_doesNotRequireModel() {
        for shape in JobShape.allCases {
            #expect(shape.requiresModel == (shape != .reson8Prerecorded),
                    "unexpected requiresModel for \(shape)")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobShapeRequiresModel`
Expected: FAILS TO COMPILE — `value of type 'JobShape' has no member 'requiresModel'`. (Red.)

- [ ] **Step 3: Add `requiresModel` to `JobShape`**

In `JobShape.swift`, add after the `baseURLPathHint` computed property (before the closing `}` of the enum):

```swift
    // Whether a Job for this shape needs a model identifier. False only for
    // shapes whose endpoint uses a server-side default with no required model
    // (Reson8). The Job editor hides the Model field and drops it from the Save
    // gate when this is false.
    public var requiresModel: Bool {
        switch self {
        case .chatCompletionsAudio, .transcriptionMultipart, .cohereTranscribe,
             .elevenLabsScribe, .geminiGenerateContent, .sonioxAsync, .deepgramListen:
            return true
        case .reson8Prerecorded:
            return false
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobShapeRequiresModel`
Expected: PASS.

- [ ] **Step 5: Gate the Model row in the Job editor**

In `Amanuensis/UI/Jobs/JobEditorView.swift`, wrap the Model `HStack` (lines 110-120) in a `requiresModel` check:

```swift
                    if preset?.shape.requiresModel ?? true {
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
                    }
```

- [ ] **Step 6: Relax the Save gate**

In `JobEditorView.swift`, change `canSave` (lines 159-165) so the non-empty-model requirement only applies when the shape requires a model:

```swift
    private var canSave: Bool {
        let folderOK = !customOutputFolder || !outputFolderPath.isEmpty
        // provider != nil (not just providerID != nil) — guards against the
        // repair-pane case where providerID still holds the dangling UUID of
        // a deleted Provider and the user hits Save without touching the Picker.
        let modelOK = !(preset?.shape.requiresModel ?? true) || !model.isEmpty
        return !name.isEmpty && provider != nil && modelOK && folderOK
    }
```

- [ ] **Step 7: Run the whole SPM suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — entire package suite green.

- [ ] **Step 8: Build the app target (verifies the SwiftUI change compiles)**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (SPM green ≠ app compiles — this is the required app-target confirmation per `CLAUDE.md`. Redirect output to a readable file if the daemon doesn't stream it inline; do not paste-copy.)

- [ ] **Step 9: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift \
        Amanuensis/UI/Jobs/JobEditorView.swift
git commit -m "$(cat <<'EOF'
feat(jobs): hide Model field for shapes that need no model

Reson8 uses a server-side default model. Add JobShape.requiresModel (false only
for reson8Prerecorded); the Job editor hides the Model row and drops it from the
Save gate when false.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**1. Spec coverage** (checked each spec section against a task):
- Cohere `cohereTranscribe` shape + path-param handler reuse → Task 1 ✓
- Cohere FieldSpec (language required, temperature, no prompt) → Task 1 Step 4 ✓
- Cohere preset fix (shape, drop prompt overrides) → Task 1 Step 8 ✓
- Cohere handler registration → Task 1 Step 7 ✓
- Reson8 `reson8Prerecorded` shape + FieldSpec → Task 2 Steps 3-4 ✓
- Reson8 handler (ApiKey auth, octet-stream, query params, no model, segments→Speaker N:, json pretty, 600 s, LocalizedError) → Task 2 Step 5 ✓
- Reson8 no-compression (raw body) → Task 2 Step 5 (no `prepareUpload`) ✓
- Reson8 preset add → Task 2 Step 7 ✓
- `requiresModel` + Job editor conditional Model field + canSave → Task 3 ✓
- Tests: CohereTranscribeHandlerTests, Reson8PrerecordedHandlerTests, PresetsStoreTests updates, JobShape requiresModel test → Tasks 1-3 ✓
- App-target rebuild after SPM changes → Task 3 Step 8 ✓
- Verification of "does the editor force a model" open risk → resolved in design (it does, via hardcoded field + canSave); addressed by Task 3 ✓

**2. Placeholder scan:** No TBD/TODO/"add error handling"/"similar to Task N". Every code step shows full code. ✓

**3. Type consistency:**
- `DefaultCohereSender.transcriptionsPath` defined in Task 1 Step 6, referenced in Task 1 Step 1 test ✓
- `path:` param default `"/v1/audio/transcriptions"` consistent across `buildRequest` and both `send` overloads (Task 1 Step 5) ✓
- `Reson8PrerecordedHandler` member names (`buildRequest`, `format`, `send`, `BuildError.audioReadFailed`, `SendError.httpError`/`.malformedResponse`, `Response.Segment.speakerID`/`speaker_id`) match between tests (Task 2 Step 1) and implementation (Task 2 Step 5) ✓
- `JobShape.requiresModel` switch covers all 8 cases (6 original + cohereTranscribe + reson8Prerecorded) ✓
- `PresetsStoreTests` count: 14 unchanged in Task 1 (cohere shape change, no new id), bumped to 15 in Task 2 (reson8 added) ✓
- `everyPromptOrContextField_hasTooltip` still passes: neither new shape exposes a prompt/context/keyterm field ✓
