# Soniox Async Handler — Design

**Date:** 2026-06-12
**Status:** Approved (brainstorm)
**Scope:** `AudioPipelineJobs` SPM target — new `sonioxAsync` shape (`SonioxAsyncHandler`, `JobShape`, `FieldSpec`, `JobRunner` registration, `presets.json`). No UI or `AppCoordinator` changes.

## Goal

Add a working Soniox async (speech-to-text) transport so a Job whose Provider uses a new `soniox-async` preset actually transcribes `combined.flac`. Unlike every existing shape — all single request/response — Soniox async is a multi-step job: upload the file, create a transcription, poll until it finishes, then fetch the transcript. This is the first polling transport in the codebase, and the first that sidesteps the synchronous-upload size ceiling (Groq/OpenAI reject >25 MB; `TranscriptionMultipartHandler` compresses to fit). Soniox async is built for long audio, so no client-side compression is needed.

## Non-goals

- No `audio_url` ingest — the app transcribes a local sandboxed file, so only the Files-API upload path is used.
- No translation, `client_reference_id`, per-token timestamps/confidence in the output, or `enable_endpoint_detection`/custom-vocabulary endpoints beyond the four chosen fields.
- No client-side compression or chunking (the deliberate advantage over the Groq 25 MB path).
- No UI changes — `FieldSpec.sonioxAsync` and the generic `JobFieldFormView` render the fields automatically; `AppCoordinator.runJob` already resolves a job's shape from its preset, so a new shape + handler + preset is picked up without touching it.

## Wire format (grounded in the Soniox async docs)

Base URL `https://api.soniox.com`; auth `Authorization: Bearer <key>` on every request.

### 1. Upload file
```
POST {baseURL}/v1/files
Authorization: Bearer <key>
Content-Type: multipart/form-data; boundary=Boundary-<uuid>

parts:
  file ← combined.flac bytes  (filename="combined.flac", Content-Type: audio/flac)

→ 200 { "id": "<file_id>" }
```

### 2. Create transcription
```
POST {baseURL}/v1/transcriptions
Authorization: Bearer <key>
Content-Type: application/json

{
  "model": "<job.model>",                              (required)
  "file_id": "<file_id>",                              (required)
  "enable_speaker_diarization": true,                  (optional — from fields)
  "language_hints": ["en","es"],                       (optional — from fields)
  "enable_language_identification": true,              (optional — from fields)
  "context": { "text": "<context>" }                   (optional — from fields)
}

→ 200 { "id": "<transcription_id>" }
```
Optional keys are emitted only when the corresponding `job.fields` value is present and non-empty. Checkboxes (`"true"`/`"false"`) emit a JSON bool; `language_hints` splits on comma, trims, drops empties; `context` becomes `{"text": "<value>"}`.

### 3. Poll status
```
GET {baseURL}/v1/transcriptions/{transcription_id}
Authorization: Bearer <key>

→ 200 { "id": "...", "status": "queued|processing|completed|error", "error_message": "..." }
```
Repeat every `pollInterval` (default 3 s). `queued`/`processing` → keep waiting; `completed` → proceed to step 4; `error` → throw `transcriptionFailed(error_message)`; wall-clock past `deadline` (default 600 s) → throw `timedOut`.

### 4. Fetch transcript
```
GET {baseURL}/v1/transcriptions/{transcription_id}/transcript
Authorization: Bearer <key>

→ 200 { "tokens": [ { "text": " Hello", "speaker": 1, "language": "en", ... }, ... ] }
```
Each token's `text` carries its own spacing (matches Soniox's `render_tokens`, which concatenates `token.text` directly), so the transcript is rebuilt by concatenation — no manual word-joining. *Assumption to confirm against a live response during implementation; the diarized-grouping and plain-fallback formatting below are robust either way.*

### 5. Cleanup (best-effort)
```
DELETE {baseURL}/v1/transcriptions/{transcription_id}
DELETE {baseURL}/v1/files/{file_id}
```
Run in a `defer`; failures are swallowed and never fail the job.

## New file: `SonioxAsyncHandler.swift`

Mirrors `ElevenLabsScribeHandler`: a `public enum` with one static `build*Request` per wire step plus an orchestrating `send`, wrapped by `DefaultSonioxAsyncSender` conforming to the shared `AudioJobSending` protocol so `JobRunner` can inject a fake in tests.

```swift
public enum SonioxAsyncHandler {
    enum BuildError: Error, Equatable { case missingModel, invalidBaseURL, audioReadFailed }
    enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
        case transcriptionFailed(message: String)
        case timedOut
    }

    static func buildUploadRequest(provider:audioURL:apiKey:) throws -> URLRequest
    static func buildCreateRequest(job:provider:fileID:apiKey:) throws -> URLRequest
    static func buildPollRequest(provider:transcriptionID:apiKey:) throws -> URLRequest
    static func buildTranscriptRequest(provider:transcriptionID:apiKey:) throws -> URLRequest
    static func buildDeleteTranscriptionRequest(provider:transcriptionID:apiKey:) throws -> URLRequest
    static func buildDeleteFileRequest(provider:fileID:apiKey:) throws -> URLRequest

    static func format(data:outputExt:) throws -> String

    static func send(
        job:provider:audioURL:apiKey:
        session: URLSession = defaultSession,
        pollInterval: Duration = .seconds(3),
        deadline: Duration = .seconds(600)
    ) async throws -> String
}
```

- `buildCreateRequest` throws `missingModel` when `job.model` is empty, `invalidBaseURL` when an endpoint won't form; the upload builder throws `audioReadFailed` when the file can't be read.
- Each request sets `Authorization: Bearer <key>`. Upload is hand-built multipart (`Boundary-\(UUID().uuidString)`, single `file` part); create is `JSONSerialization` JSON; poll/transcript/delete are bodiless GET/DELETE.
- `baseURL` trailing slash is trimmed once (same helper idiom as the sibling handlers).
- `send` runs upload → create → poll-loop → transcript, checks `(200..<300)` on every response (else `httpError(status, body)`), `defer`s best-effort cleanup, and returns the formatted transcript. The poll loop sleeps `pollInterval` between polls and tracks elapsed time against `deadline` using an injected clock-free counter (sum of slept intervals) so tests stay deterministic with a tiny `pollInterval`.

`defaultSession` uses `timeoutIntervalForRequest = 600` to match the sibling handlers (each individual request — esp. the upload of a large FLAC — must not hit URLSession's 60 s inactivity default).

## Output formatting

`format` returns the exact string `JobRunner` writes to `combined-<job>.<outputExt>`, chosen by `job.outputExt`:

- **`json`** → the transcript response body, pretty-printed (key-sorted, stable).
- **anything else** → **labelled transcript**: walk `tokens[]`, group consecutive tokens by `speaker`, emit one `Speaker N: <concatenated, trimmed text>` line per run, `N` assigned in first-seen order of `speaker`. If **no** token carries a `speaker` (diarization off), fall back to plain concatenation of every `token.text`, trimmed.

Labelling keys off what's actually in the response, not the request flag, so it stays correct regardless of how `enable_speaker_diarization` was set — identical philosophy to the ElevenLabs handler.

## Shape, fields, dispatch, preset

**`JobShape.swift`** — add `case sonioxAsync`; `baseURLPathHint` → `/v1/transcriptions` (representative hint for the provider editor; the handler builds several paths under the base).

**`FieldSpec.swift`** — add the `.sonioxAsync` case:
```swift
FieldSpec(key: "enable_speaker_diarization", label: "Speaker diarization", kind: .checkbox, required: false)
FieldSpec(key: "language_hints", label: "Language hints", kind: .text, required: false,
          help: "Comma-separated ISO codes, e.g. en,es")
FieldSpec(key: "enable_language_identification", label: "Language identification", kind: .checkbox, required: false)
FieldSpec(key: "context", label: "Context / vocabulary", kind: .longText, required: false,
          help: "Bias toward names/jargon; sent as context.text")
```

**`JobRunner.swift`** — register `.sonioxAsync: DefaultSonioxAsyncSender()` in `defaultHandlers`. No signature change (dispatch + `shape:` param already exist).

**`presets.json`** — append:
```json
{"id":"soniox-async","displayName":"Soniox Async","shape":"sonioxAsync",
 "baseURL":"https://api.soniox.com","suggestedModels":["stt-async-v4"],
 "defaults":{"enable_speaker_diarization":"true"},
 "docsURL":"https://soniox.com/docs/stt/async/async-transcription"}
```
Diarization defaults on, mirroring the `elevenlabs` preset's `diarize:true`.

## Testing (SPM, fully offline)

- **`SonioxAsyncHandlerTests`** (`MockURLProtocol` stubs, as in `TranscriptionMultipartHandlerTests`)
  - `buildUploadRequest`: `POST /v1/files`, `Bearer` header, multipart boundary present, body carries the `file` part with filename.
  - `buildCreateRequest`: `POST /v1/transcriptions`, `application/json`, body has `model` + `file_id`; emits each optional key only when set; `language_hints` "en, es" → `["en","es"]`; checkbox `"true"` → JSON `true`; `context` → `{"text": …}`; throws `missingModel` on empty `job.model`.
  - `buildPollRequest` / `buildTranscriptRequest` / delete builders: correct method, path, `Bearer` header.
  - `send` poll loop: stub sequence `processing` → `completed` then a transcript reaches `format` (use a tiny `pollInterval`); a `error` status throws `transcriptionFailed`; never-completing stub past a tiny `deadline` throws `timedOut`.
  - `format`: diarized sample → `Speaker 1:` / `Speaker 2:` lines; no-speaker sample → plain concatenated text; `outputExt == "json"` → pretty passthrough.
- **`PresetsStoreTests`** (extend): bundled count bumps from 10 to 11; `preset(id: "soniox-async")` resolves with shape `.sonioxAsync` and model `stt-async-v4`.
- **`JobRunnerTests`** (extend): routes `.sonioxAsync` → a fake `DefaultSonioxAsyncSender` substitute, confirming dispatch.

## Files touched

- New: `Packages/AudioPipeline/Sources/AudioPipelineJobs/SonioxAsyncHandler.swift`
- New: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/SonioxAsyncHandlerTests.swift`
- Modify: `Sources/AudioPipelineJobs/JobShape.swift` (`sonioxAsync` case + `baseURLPathHint`)
- Modify: `Sources/AudioPipelineJobs/FieldSpec.swift` (`.sonioxAsync` fields)
- Modify: `Sources/AudioPipelineJobs/JobRunner.swift` (register handler in `defaultHandlers`)
- Modify: `Sources/AudioPipelineJobs/Resources/presets.json` (`soniox-async` entry)
- Modify: `Tests/AudioPipelineJobsTests/PresetsStoreTests.swift` (count + lookup)
- Modify: `Tests/AudioPipelineJobsTests/JobRunnerTests.swift` (dispatch case)
