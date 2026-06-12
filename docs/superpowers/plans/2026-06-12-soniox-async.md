# Soniox Async Handler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a working `sonioxAsync` transcription shape so a Job whose Provider uses a new `soniox-async` preset transcribes `combined.flac` via Soniox's multi-step async API (upload → create → poll → fetch → cleanup).

**Architecture:** Mirror the existing per-shape handler pattern (`enum XHandler` with static request builders + an orchestrating `send`, wrapped by `DefaultXSender: AudioJobSending`, registered in `JobRunner.defaultHandlers`). New here: `send` is a polling orchestration (not one request), and request building spans five endpoints. Output rendering mirrors `ElevenLabsScribeHandler` (speaker-grouped labelled transcript, JSON passthrough). No client-side compression — Soniox async is built for long audio.

**Tech Stack:** Swift 6.2, Foundation `URLSession`/`URLRequest`/`JSONSerialization`/`JSONDecoder`, Swift `Duration`/`Task.sleep(for:)`, Swift Testing (`@Suite`/`@Test`/`#expect`). SPM target `AudioPipelineJobs`.

**Reference files (read before starting):**
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift` — closest sibling (multipart build, speaker grouping, `defaultSession`, `DefaultXSender`).
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/ChatCompletionsAudioHandler.swift` — `JSONSerialization` body idiom.
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/TranscriptionMultipartHandlerTests.swift` — stub-`URLProtocol` + Swift Testing idioms + `TranscriptionMultipartDispatch` suite.

**Test command (SPM, runs inside the Claude Code sandbox):**
```
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsync
```
Full suite (Task 11): `swift test --disable-sandbox --package-path Packages/AudioPipeline`

> ⚠️ A failing Swift *compile* (referencing a not-yet-written function) is the valid TDD "red" state — the whole test target won't build, and the error names the missing symbol. That's expected on every "verify it fails" step here.

---

## File Structure

- **Create** `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift` — the handler enum, response models, `DefaultSonioxAsyncSender`.
- **Create** `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift` — all handler tests + the stub `URLProtocol`.
- **Modify** `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift` — `sonioxAsync` case + `baseURLPathHint`.
- **Modify** `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift` — `.sonioxAsync` field specs.
- **Modify** `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift` — register the handler.
- **Modify** `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json` — `soniox-async` entry.
- **Modify** `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift` — count bump + lookup.

> The `sonioxAsync` dispatch-registration check lives in `SonioxAsyncHandlerTests.swift` (Task 9), mirroring `TranscriptionMultipartDispatch` in its own file — so `JobRunnerTests.swift` is **not** touched (a refinement over the spec, which had named it; this matches the codebase convention).

---

## Task 1: Declare the `sonioxAsync` shape (enum case + path hint + field specs)

Adding the enum case alone breaks the two exhaustive switches over `JobShape` (`baseURLPathHint` in `JobShape.swift`, `fields` in `FieldSpec.swift`), so both are updated together to keep the package compiling.

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncShapeTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncShapeTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct SonioxAsyncShape {
    @Test func baseURLPathHint_isTranscriptionsPath() {
        #expect(JobShape.sonioxAsync.baseURLPathHint == "/v1/transcriptions")
    }

    @Test func fields_exposeTheFourChosenKnobs() {
        let keys = JobShape.sonioxAsync.fields.map(\.key)
        #expect(keys == [
            "enable_speaker_diarization",
            "language_hints",
            "enable_language_identification",
            "context",
        ])
    }

    @Test func diarizationField_isCheckbox_andContextIsLongText() {
        let fields = JobShape.sonioxAsync.fields
        let diarize = try? #require(fields.first { $0.key == "enable_speaker_diarization" })
        #expect(diarize?.kind == .checkbox)
        let context = try? #require(fields.first { $0.key == "context" })
        #expect(context?.kind == .longText)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncShape`
Expected: FAIL — compile error, `type 'JobShape' has no member 'sonioxAsync'`.

- [ ] **Step 3: Add the enum case + path hint**

In `JobShape.swift`, add the case after `geminiGenerateContent` (line 8) and a hint arm in the `switch` (after line 20):

```swift
    case geminiGenerateContent      // Gemini File API + generateContent
    case sonioxAsync                // Soniox async: upload → create → poll → fetch transcript
```

```swift
        case .geminiGenerateContent: return "/models/{model}:generateContent"
        case .sonioxAsync:           return "/v1/transcriptions"
```

- [ ] **Step 4: Add the field specs**

In `FieldSpec.swift`, add a new arm to the `switch self` in `var fields` (after the `.geminiGenerateContent` case, before the closing brace of the switch):

```swift
        case .sonioxAsync:
            return [
                FieldSpec(key: "enable_speaker_diarization", label: "Speaker diarization",
                          kind: .checkbox, required: false),
                FieldSpec(key: "language_hints", label: "Language hints", kind: .text, required: false,
                          help: "Comma-separated ISO codes, e.g. en,es"),
                FieldSpec(key: "enable_language_identification", label: "Language identification",
                          kind: .checkbox, required: false),
                FieldSpec(key: "context", label: "Context / vocabulary", kind: .longText, required: false,
                          help: "Bias toward names/jargon; sent as context.text"),
            ]
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncShape`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncShapeTests.swift
git commit -m "feat(jobs): declare sonioxAsync shape with path hint and field specs"
```

---

## Task 2: Add the `soniox-async` preset

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

In `PresetsStoreTests.swift`, change the count assertion on line 14 from `10` to `11`, and add a new test to the `PresetsStoreBehavior` suite:

```swift
        #expect(store.all.count == 11)
```

```swift
    @Test func lookupByID_sonioxAsync_returnsPreset() throws {
        let store = try PresetsStore.loadBundled()
        let preset = store.preset(id: "soniox-async")
        #expect(preset?.shape == .sonioxAsync)
        #expect(preset?.suggestedModels.contains("stt-async-v4") == true)
        #expect(preset?.defaults["enable_speaker_diarization"] == "true")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter PresetsStore`
Expected: FAIL — `loadsAllBundledPresets` (count is 10, expected 11) and `lookupByID_sonioxAsync_returnsPreset` (preset is nil).

- [ ] **Step 3: Add the preset entry**

In `presets.json`, append a new object as the last array element (add a comma after the current last `gemini` entry's closing `}`):

```json
  {"id":"soniox-async","displayName":"Soniox Async","shape":"sonioxAsync",
   "baseURL":"https://api.soniox.com","suggestedModels":["stt-async-v4"],
   "defaults":{"enable_speaker_diarization":"true"},
   "docsURL":"https://soniox.com/docs/stt/async/async-transcription"}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter PresetsStore`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/PresetsStoreTests.swift
git commit -m "feat(jobs): add soniox-async preset"
```

---

## Task 3: Handler skeleton + upload request

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift` with the shared helpers and the first suite:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

// MARK: - Shared fixtures

private func makeProvider(baseURL: String = "https://api.soniox.com") -> Provider {
    Provider(name: "p", presetID: "soniox-async",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "soniox"))
}

private func makeJob(
    model: String = "stt-async-v4",
    diarization: String? = nil,
    languageHints: String? = nil,
    languageIdentification: String? = nil,
    context: String? = nil,
    outputExt: String = "txt"
) -> Job {
    var fields: [String: String] = [:]
    if let diarization { fields["enable_speaker_diarization"] = diarization }
    if let languageHints { fields["language_hints"] = languageHints }
    if let languageIdentification { fields["enable_language_identification"] = languageIdentification }
    if let context { fields["context"] = context }
    return Job(name: "t", providerID: UUID(), model: model, fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sx-audio-\(UUID().uuidString).flac")
    try Data(bytes).write(to: url)
    return url
}

// MARK: - Upload request

@Suite struct SonioxAsyncUploadRequest {
    @Test func buildsPOST_toFilesPath_withBearer_andMultipart() throws {
        let req = try SonioxAsyncHandler.buildUploadRequest(
            provider: makeProvider(), audioURL: try writeAudio([0x01, 0x02]), apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/files")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        let ct = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test func body_includesFilePart_withBytes() throws {
        let audio = try writeAudio([0xAA, 0xBB, 0xCC])
        let req = try SonioxAsyncHandler.buildUploadRequest(
            provider: makeProvider(), audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"file\"; filename=\"\(audio.lastPathComponent)\""))
        #expect(body.range(of: Data([0xAA, 0xBB, 0xCC])) != nil)
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try SonioxAsyncHandler.buildUploadRequest(
                provider: makeProvider(), audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch SonioxAsyncHandler.BuildError.audioReadFailed {
            // expected
        }
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let req = try SonioxAsyncHandler.buildUploadRequest(
            provider: makeProvider(baseURL: "https://api.soniox.com/"),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/files")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncUploadRequest`
Expected: FAIL — compile error, `cannot find 'SonioxAsyncHandler' in scope`.

- [ ] **Step 3: Create the handler file with skeleton + upload builder**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`:

```swift
import Foundation

// HTTP handler for the Soniox async speech-to-text API (the "sonioxAsync" shape).
//
// Unlike the synchronous handlers, transcription is a multi-step job:
//   1. POST {baseURL}/v1/files                 (multipart) → file_id
//   2. POST {baseURL}/v1/transcriptions        (json: model + file_id + options) → transcription_id
//   3. GET  {baseURL}/v1/transcriptions/{id}   poll until status == "completed"
//   4. GET  {baseURL}/v1/transcriptions/{id}/transcript → { tokens: [...] }
//   5. DELETE the transcription and the file   (best-effort cleanup)
// Every request carries `Authorization: Bearer <key>`. No client-side
// compression: Soniox async handles long audio (unlike the 25 MB sync cap).
public enum SonioxAsyncHandler {
    public enum BuildError: Error, Equatable {
        case missingModel
        case invalidBaseURL
        case audioReadFailed
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
        case transcriptionFailed(message: String)
        case timedOut
    }

    // Trims one trailing slash and appends a path; the single place base-URL
    // composition happens for every step.
    private static func endpoint(_ provider: Provider, _ path: String) throws -> URL {
        let trimmed = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let url = URL(string: trimmed + path) else { throw BuildError.invalidBaseURL }
        return url
    }

    // Step 1: multipart upload of the audio file. Content-Type is fixed to
    // audio/flac — the app only ever uploads combined.flac.
    public static func buildUploadRequest(provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        let url = try endpoint(provider, "/v1/files")
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/flac\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncUploadRequest`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift
git commit -m "feat(jobs): SonioxAsyncHandler upload request builder"
```

---

## Task 4: Create-transcription request (field mapping)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SonioxAsyncHandlerTests.swift`:

```swift
// MARK: - Create transcription request

@Suite struct SonioxAsyncCreateRequest {
    private func decodeBody(_ req: URLRequest) throws -> [String: Any] {
        let data = try #require(req.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func buildsPOST_toTranscriptionsPath_withModelAndFileID() throws {
        let req = try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(model: "stt-async-v4"), provider: makeProvider(), fileID: "file_9", apiKey: "k")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try decodeBody(req)
        #expect(body["model"] as? String == "stt-async-v4")
        #expect(body["file_id"] as? String == "file_9")
    }

    @Test func throws_missingModel_whenModelEmpty() throws {
        do {
            _ = try SonioxAsyncHandler.buildCreateRequest(
                job: makeJob(model: ""), provider: makeProvider(), fileID: "f", apiKey: "k")
            Issue.record("expected missingModel")
        } catch SonioxAsyncHandler.BuildError.missingModel {
            // expected
        }
    }

    @Test func omitsOptionalKeys_whenAbsent() throws {
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(), provider: makeProvider(), fileID: "f", apiKey: "k"))
        #expect(body["enable_speaker_diarization"] == nil)
        #expect(body["language_hints"] == nil)
        #expect(body["enable_language_identification"] == nil)
        #expect(body["context"] == nil)
    }

    @Test func mapsCheckboxesToBools_hintsToArray_contextToObject() throws {
        let job = makeJob(diarization: "true", languageHints: "en, es",
                          languageIdentification: "true", context: "Volvo, Skåne")
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: job, provider: makeProvider(), fileID: "f", apiKey: "k"))
        #expect(body["enable_speaker_diarization"] as? Bool == true)
        #expect(body["enable_language_identification"] as? Bool == true)
        #expect(body["language_hints"] as? [String] == ["en", "es"])
        let ctx = try #require(body["context"] as? [String: Any])
        #expect(ctx["text"] as? String == "Volvo, Skåne")
    }

    @Test func diarizationFalse_emitsBoolFalse() throws {
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(diarization: "false"), provider: makeProvider(), fileID: "f", apiKey: "k"))
        #expect(body["enable_speaker_diarization"] as? Bool == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncCreateRequest`
Expected: FAIL — compile error, `type 'SonioxAsyncHandler' has no member 'buildCreateRequest'`.

- [ ] **Step 3: Implement `buildCreateRequest`**

In `SonioxAsyncHandler.swift`, add inside the enum (after `buildUploadRequest`):

```swift
    // Step 2: create the transcription job. Required: model + file_id. Optional
    // keys are emitted only when their job.field is present & non-empty:
    //   enable_speaker_diarization / enable_language_identification → JSON bool
    //   language_hints "en, es" → ["en","es"]   context "<text>" → {"text": …}
    public static func buildCreateRequest(job: Job, provider: Provider, fileID: String, apiKey: String) throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }
        let url = try endpoint(provider, "/v1/transcriptions")

        var payload: [String: Any] = ["model": job.model, "file_id": fileID]
        if let v = job.fields["enable_speaker_diarization"], !v.isEmpty {
            payload["enable_speaker_diarization"] = (v == "true")
        }
        if let hints = job.fields["language_hints"], !hints.isEmpty {
            let arr = hints.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !arr.isEmpty { payload["language_hints"] = arr }
        }
        if let v = job.fields["enable_language_identification"], !v.isEmpty {
            payload["enable_language_identification"] = (v == "true")
        }
        if let ctx = job.fields["context"], !ctx.isEmpty {
            payload["context"] = ["text": ctx]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return req
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncCreateRequest`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift
git commit -m "feat(jobs): SonioxAsyncHandler create-transcription request builder"
```

---

## Task 5: Poll, transcript, and delete request builders

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SonioxAsyncHandlerTests.swift`:

```swift
// MARK: - Poll / transcript / delete requests

@Suite struct SonioxAsyncOtherRequests {
    @Test func pollRequest_isGET_toTranscriptionPath() throws {
        let req = try SonioxAsyncHandler.buildPollRequest(
            provider: makeProvider(), transcriptionID: "tx_7", apiKey: "k")
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions/tx_7")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func transcriptRequest_isGET_toTranscriptSubpath() throws {
        let req = try SonioxAsyncHandler.buildTranscriptRequest(
            provider: makeProvider(), transcriptionID: "tx_7", apiKey: "k")
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions/tx_7/transcript")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func deleteTranscription_isDELETE() throws {
        let req = try SonioxAsyncHandler.buildDeleteTranscriptionRequest(
            provider: makeProvider(), transcriptionID: "tx_7", apiKey: "k")
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions/tx_7")
    }

    @Test func deleteFile_isDELETE() throws {
        let req = try SonioxAsyncHandler.buildDeleteFileRequest(
            provider: makeProvider(), fileID: "file_3", apiKey: "k")
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/files/file_3")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncOtherRequests`
Expected: FAIL — compile error, `no member 'buildPollRequest'`.

- [ ] **Step 3: Implement the four builders**

In `SonioxAsyncHandler.swift`, add inside the enum (after `buildCreateRequest`):

```swift
    // Step 3: poll one transcription's status.
    public static func buildPollRequest(provider: Provider, transcriptionID: String, apiKey: String) throws -> URLRequest {
        get(try endpoint(provider, "/v1/transcriptions/\(transcriptionID)"), apiKey: apiKey)
    }

    // Step 4: fetch the finished transcript (tokens).
    public static func buildTranscriptRequest(provider: Provider, transcriptionID: String, apiKey: String) throws -> URLRequest {
        get(try endpoint(provider, "/v1/transcriptions/\(transcriptionID)/transcript"), apiKey: apiKey)
    }

    // Step 5a/5b: best-effort cleanup.
    static func buildDeleteTranscriptionRequest(provider: Provider, transcriptionID: String, apiKey: String) throws -> URLRequest {
        delete(try endpoint(provider, "/v1/transcriptions/\(transcriptionID)"), apiKey: apiKey)
    }

    static func buildDeleteFileRequest(provider: Provider, fileID: String, apiKey: String) throws -> URLRequest {
        delete(try endpoint(provider, "/v1/files/\(fileID)"), apiKey: apiKey)
    }

    private static func get(_ url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func delete(_ url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }
```

> Note: `get`/`delete` take an already-built `URL` and don't throw; the single `try` sits on `endpoint(...)` (which can throw `invalidBaseURL`). The wrappers are `throws` for that reason. Do **not** add a second `try` in front of `get`/`delete` — Swift would flag it.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncOtherRequests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift
git commit -m "feat(jobs): SonioxAsyncHandler poll/transcript/delete request builders"
```

---

## Task 6: Output formatting (`format` + response models)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SonioxAsyncHandlerTests.swift`:

```swift
// MARK: - Output formatting

@Suite struct SonioxAsyncFormat {
    @Test func diarizedTokens_renderSpeakerLabels() throws {
        let data = Data(#"{"tokens":[{"text":" Hi","speaker":1},{"text":" there","speaker":1},{"text":" Bye","speaker":2}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "txt")
        #expect(out == "Speaker 1: Hi there\nSpeaker 2: Bye")
    }

    @Test func tokensWithoutSpeaker_renderPlainConcatenatedText() throws {
        let data = Data(#"{"tokens":[{"text":"Hello"},{"text":" world"}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "txt")
        #expect(out == "Hello world")
    }

    @Test func jsonOutput_prettyPrintsRaw() throws {
        let data = Data(#"{"tokens":[{"text":"Hi","speaker":1}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "json")
        #expect(out.contains("\"tokens\""))
        #expect(out.contains("\n"))   // pretty-printed → multiline
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try SonioxAsyncHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.malformedResponse {
            // expected
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncFormat`
Expected: FAIL — compile error, `no member 'format'`.

- [ ] **Step 3: Implement `format` + response models**

In `SonioxAsyncHandler.swift`, add inside the enum (after the delete builders):

```swift
    // Maps the transcript response to the string JobRunner writes. "json" → the
    // raw body pretty-printed (sorted keys, stable); anything else → speaker-
    // labelled transcript, falling back to plain concatenated text when no token
    // carries a speaker. Keys off the actual response, not the request flag.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard let resp = try? JSONDecoder().decode(TranscriptResponse.self, from: data) else {
            throw SendError.malformedResponse
        }
        return resp.labelledTranscript()
    }

    // Token text carries its own spacing (Soniox concatenates token.text), so the
    // transcript is rebuilt by joining without separators.
    struct TranscriptResponse: Decodable {
        struct Token: Decodable {
            let text: String
            let speaker: Int?
        }
        let tokens: [Token]

        func labelledTranscript() -> String {
            guard tokens.contains(where: { $0.speaker != nil }) else {
                return tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var runs: [(speaker: Int, text: String)] = []
            for t in tokens {
                if let s = t.speaker, runs.last?.speaker != s {
                    runs.append((s, t.text))
                } else if !runs.isEmpty {
                    runs[runs.count - 1].text += t.text
                }
                // Tokens before the first identified speaker are dropped, matching
                // the ElevenLabs handler — no phantom "Speaker 1".
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
                return "Speaker \(n): \(run.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return lines.joined(separator: "\n")
        }
    }

    // Step 1/2 responses: { "id": "..." }.
    struct IDResponse: Decodable { let id: String }

    // Step 3 response: { "status": "...", "error_message": "..." }.
    struct StatusResponse: Decodable {
        let status: String
        let errorMessage: String?
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncFormat`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift
git commit -m "feat(jobs): SonioxAsyncHandler transcript formatting"
```

---

## Task 7: `send` orchestration (upload → create → poll → fetch → cleanup)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test (stub + happy path + error + timeout)**

Append to `SonioxAsyncHandlerTests.swift`:

```swift
// MARK: - send() orchestration

// Closure-routed URLProtocol stub: the test inspects (method, path) and returns
// (status, body). `pollCount` lets a test sequence "processing" → "completed".
final class SonioxStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var pollCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SonioxStubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct SonioxAsyncSend {
    @Test func send_uploadsCreatesPollsThenFormatsTranscript() async throws {
        SonioxStubProtocol.pollCount = 0
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"):
                return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"):
                return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"):
                SonioxStubProtocol.pollCount += 1
                let status = SonioxStubProtocol.pollCount >= 2 ? "completed" : "processing"
                return (200, Data("{\"status\":\"\(status)\"}".utf8))
            case ("GET", "/v1/transcriptions/tx_1/transcript"):
                return (200, Data(#"{"tokens":[{"text":" Hello","speaker":1},{"text":" world","speaker":1}]}"#.utf8))
            case ("DELETE", _):
                return (200, Data())
            default:
                return (404, Data())
            }
        }
        let text = try await SonioxAsyncHandler.send(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k",
            session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
        #expect(text == "Speaker 1: Hello world")
        #expect(SonioxStubProtocol.pollCount == 2)
    }

    @Test func send_throwsTranscriptionFailed_whenStatusError() async throws {
        SonioxStubProtocol.pollCount = 0
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"): return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"): return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"):
                return (200, Data(#"{"status":"error","error_message":"bad audio"}"#.utf8))
            case ("DELETE", _): return (200, Data())
            default: return (404, Data())
            }
        }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.transcriptionFailed(let message) {
            #expect(message == "bad audio")
        }
    }

    @Test func send_throwsTimedOut_whenNeverCompletes() async throws {
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"): return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"): return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"): return (200, Data(#"{"status":"processing"}"#.utf8))
            case ("DELETE", _): return (200, Data())
            default: return (404, Data())
            }
        }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .milliseconds(3))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.timedOut {
            // expected
        }
    }

    @Test func send_throwsHTTPError_whenUploadFails() async throws {
        SonioxStubProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.httpError(let status, _) {
            #expect(status == 401)
        }
    }
}

@Suite struct SonioxAsyncSession {
    @Test func defaultSession_usesGenerousRequestTimeout() {
        #expect(SonioxAsyncHandler.requestTimeout >= 300)
        #expect(SonioxAsyncHandler.defaultSession.configuration.timeoutIntervalForRequest
                == SonioxAsyncHandler.requestTimeout)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncSend`
Expected: FAIL — compile error, `no member 'send'` / `no member 'defaultSession'`.

- [ ] **Step 3: Implement `send` + private orchestration helpers + `defaultSession`**

In `SonioxAsyncHandler.swift`, add inside the enum (after the response models):

```swift
    // Each individual request (esp. the multipart upload of a large FLAC) must
    // not hit URLSession's 60s inactivity default — same trap the sync handlers
    // hit. The poll loop itself is bounded separately by `deadline`.
    static let requestTimeout: TimeInterval = 600

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    // Orchestrates the full async job. `pollInterval`/`deadline` are injectable so
    // tests stay fast and deterministic; the deadline is tracked as the sum of
    // slept intervals (no wall clock). The uploaded file and the transcription are
    // deleted best-effort on every exit path.
    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = SonioxAsyncHandler.defaultSession,
        pollInterval: Duration = .seconds(3),
        deadline: Duration = .seconds(600)
    ) async throws -> String {
        let fileID = try await postForID(
            try buildUploadRequest(provider: provider, audioURL: audioURL, apiKey: apiKey),
            session: session)

        var transcriptionID: String?
        do {
            let tid = try await postForID(
                try buildCreateRequest(job: job, provider: provider, fileID: fileID, apiKey: apiKey),
                session: session)
            transcriptionID = tid
            try await waitUntilComplete(provider: provider, transcriptionID: tid, apiKey: apiKey,
                                        session: session, pollInterval: pollInterval, deadline: deadline)
            let data = try await fetchData(
                try buildTranscriptRequest(provider: provider, transcriptionID: tid, apiKey: apiKey),
                session: session)
            let result = try format(data: data, outputExt: job.outputExt)
            await cleanup(provider: provider, apiKey: apiKey, fileID: fileID,
                          transcriptionID: transcriptionID, session: session)
            return result
        } catch {
            await cleanup(provider: provider, apiKey: apiKey, fileID: fileID,
                          transcriptionID: transcriptionID, session: session)
            throw error
        }
    }

    private static func postForID(_ request: URLRequest, session: URLSession) async throws -> String {
        let data = try await fetchData(request, session: session)
        guard let decoded = try? JSONDecoder().decode(IDResponse.self, from: data) else {
            throw SendError.malformedResponse
        }
        return decoded.id
    }

    private static func fetchData(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SendError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return data
    }

    private static func waitUntilComplete(
        provider: Provider, transcriptionID: String, apiKey: String,
        session: URLSession, pollInterval: Duration, deadline: Duration
    ) async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var elapsed: Duration = .zero
        while true {
            let data = try await fetchData(
                try buildPollRequest(provider: provider, transcriptionID: transcriptionID, apiKey: apiKey),
                session: session)
            guard let status = try? decoder.decode(StatusResponse.self, from: data) else {
                throw SendError.malformedResponse
            }
            switch status.status {
            case "completed":
                return
            case "error":
                throw SendError.transcriptionFailed(message: status.errorMessage ?? "")
            default:   // queued / processing
                if elapsed >= deadline { throw SendError.timedOut }
                try await Task.sleep(for: pollInterval)
                elapsed += pollInterval
            }
        }
    }

    private static func cleanup(
        provider: Provider, apiKey: String, fileID: String,
        transcriptionID: String?, session: URLSession
    ) async {
        if let tid = transcriptionID,
           let req = try? buildDeleteTranscriptionRequest(provider: provider, transcriptionID: tid, apiKey: apiKey) {
            _ = try? await session.data(for: req)
        }
        if let req = try? buildDeleteFileRequest(provider: provider, fileID: fileID, apiKey: apiKey) {
            _ = try? await session.data(for: req)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsync`
Expected: PASS (all SonioxAsync suites, including `SonioxAsyncSend` 4 tests + `SonioxAsyncSession`).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift
git commit -m "feat(jobs): SonioxAsyncHandler send orchestration with poll loop and cleanup"
```

---

## Task 8: Register the handler in `JobRunner`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift`
- Modify: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SonioxAsyncHandlerTests.swift`:

```swift
// MARK: - Dispatch registration

@Suite struct SonioxAsyncDispatch {
    @Test func jobRunner_registersSonioxAsyncHandler() {
        #expect(JobRunner.defaultHandlers[.sonioxAsync] != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncDispatch`
Expected: FAIL — `expectation failed: JobRunner.defaultHandlers[.sonioxAsync] != nil` (key absent).

- [ ] **Step 3: Add the sender adapter + register it**

In `SonioxAsyncHandler.swift`, add at the very end of the file (after the enum's closing brace and the `private extension Data`):

```swift
// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it
// (and tests can inject a fake).
public struct DefaultSonioxAsyncSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await SonioxAsyncHandler.send(job: job, provider: provider,
                                          audioURL: audioURL, apiKey: apiKey)
    }
}
```

In `JobRunner.swift`, add the entry to `defaultHandlers` (after the `.elevenLabsScribe` line):

```swift
        .elevenLabsScribe: DefaultElevenLabsScribeSender(),
        .sonioxAsync: DefaultSonioxAsyncSender(),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter SonioxAsyncDispatch`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift \
        Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift
git commit -m "feat(jobs): register SonioxAsyncHandler in JobRunner"
```

---

## Task 9: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the entire SPM test suite**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — all suites green, including every `SonioxAsync*` suite, the bumped `PresetsStoreBehavior`, and all pre-existing suites unchanged.

- [ ] **Step 2: Confirm no regressions in untouched areas**

Expected: zero failures. If `PresetsStoreBehavior.loadsAllBundledPresets` fails on count, re-check Task 2 (`presets.json` must have exactly 11 entries and the assertion must read `== 11`).

- [ ] **Step 3 (optional, outside sandbox): app-target build**

Per `CLAUDE.md`, the app target builds via the xcode-build daemon outside the sandbox. No app-target source changed (the job form and `AppCoordinator` resolve shapes/fields generically), so this is a smoke check only:
Run (via xcode-build skill): `xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: BUILD SUCCEEDED.

---

## Self-Review Notes (for the implementer)

- **Soniox token spacing assumption:** the handler concatenates `token.text` directly (Task 6), assuming each token carries its own leading space — matching Soniox's `render_tokens`. If a real transcript comes back with words run together (`Hellothere`), the fix is localized to `labelledTranscript()` / the no-speaker fallback (join with `" "` and collapse). The unit tests use space-prefixed token text to encode the expected behavior.
- **`speaker` is decoded as `Int?`** per the documented response (`"speaker": 1`). If Soniox returns speaker as a string in practice, `TranscriptResponse.Token.speaker` and the grouping types change `Int` → `String`; only Task 6 is affected.
- **Checkbox semantics:** a present-and-non-empty `"false"` emits `false` (Task 4 `diarizationFalse_emitsBoolFalse`); an absent field omits the key entirely. This is intentional — the preset defaults diarization to `"true"`, and an explicit untick should send `false`, not silently fall back to the model default.
