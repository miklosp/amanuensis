# ElevenLabs Scribe Handler — Design

**Date:** 2026-06-09
**Status:** Approved (brainstorm)
**Scope:** `AudioPipelineJobs` SPM target (`ElevenLabsScribeHandler`, `JobRunner` dispatch, `presets.json`) + a one-line shape lookup in `AppCoordinator.runJob`.

## Goal

Add a working ElevenLabs Scribe (speech-to-text) transport so a Job whose Provider uses the `elevenlabs` preset actually transcribes `combined.flac`. Today only the `chatCompletionsAudio` shape has a handler; `JobRunner` ignores the job's shape and always dispatches to `ChatCompletionsAudioSending`, so an ElevenLabs job is silently sent as the wrong wire shape and fails.

This delivers the second real transport shape and the dispatch mechanism the original providers/jobs split deferred ("Single-shape for the MVP slice; later shapes get their own sender protocol or a dispatch table inside the runner").

## Non-goals

- No webhook/async mode, `source_url`/URL ingest, multichannel, entity detection/redaction, keyterms, or regional endpoints.
- No SRT/VTT output (deferred — non-`json` output is labelled text).
- No UI changes — `FieldSpec.elevenLabsScribe` and the generic `JobFieldFormView` already render the fields.
- No implementation of the other unbuilt shapes (`transcriptionMultipart`, `geminiGenerateContent`) — they become explicit `unsupportedShape` errors.

## Wire format (grounded in the ElevenLabs docs)

```
POST {provider.baseURL}/v1/speech-to-text
xi-api-key: <key>
Content-Type: multipart/form-data; boundary=Boundary-<uuid>

parts:
  model_id        ← job.model                         (required)
  file            ← combined.flac bytes               (required; filename="combined.flac", Content-Type: audio/flac)
  language_code   ← job.fields["language_code"]        (optional)
  diarize         ← job.fields["diarize"]              (optional, "true"/"false")
  num_speakers    ← job.fields["num_speakers"]         (optional)
  timestamps_granularity ← job.fields["timestamps_granularity"]  (optional)
  tag_audio_events ← job.fields["tag_audio_events"]    (optional, "true"/"false")
```

Optional parts are emitted only when the corresponding `job.fields` value is present and non-empty.

### Response (relevant subset)

```json
{
  "language_code": "en",
  "text": "full transcript",
  "words": [
    { "text": "Hello", "start": 0.0, "end": 0.4, "type": "word", "speaker_id": "speaker_0" },
    { "text": " ",     "start": 0.4, "end": 0.4, "type": "spacing", "speaker_id": "speaker_0" }
  ]
}
```

## New file: `ElevenLabsScribeHandler.swift`

Mirrors `ChatCompletionsAudioHandler`: a `public enum` with `buildRequest` + `send`. A default sender (`DefaultElevenLabsScribeSender`) wraps the static `send` and conforms to the shared `AudioJobSending` protocol (see Dispatch) so `JobRunner` can inject a fake in tests.

```swift
public enum ElevenLabsScribeHandler {
    enum BuildError: Error, Equatable { case missingModel, invalidBaseURL, audioReadFailed }
    enum SendError: Error { case httpError(status: Int, body: Data), malformedResponse }

    static func buildRequest(job:provider:audioURL:apiKey:) throws -> URLRequest
    static func send(job:provider:audioURL:apiKey:session:) async throws -> String
}
```

- `buildRequest` throws `missingModel` when `job.model` is empty, `invalidBaseURL` when the endpoint won't form, `audioReadFailed` when the file can't be read.
- Multipart body is hand-built (Foundation has no helper): a `Boundary-\(UUID().uuidString)` delimiter, one part per form field, the `file` part last.
- `send` posts, checks `(200..<300)` (else `httpError(status, body)`), and formats the response (below).

## Output formatting

`send` returns the exact string `JobRunner` writes to `combined-<job>.<outputExt>`, chosen by `job.outputExt`:

- **`json`** → the response body, pretty-printed.
- **anything else** (`txt`, `srt`, …) → **labelled transcript**: walk `words[]`, group consecutive entries by `speaker_id`, emit one `Speaker N: <joined text>` line per run, where `N` is assigned in first-seen order of `speaker_id`. If **no** entry carries a `speaker_id` (diarize off), fall back to the top-level `text`.

The labelling keys off what is actually in the response, not the request flag, so it stays correct regardless of how `diarize` was set.

## Dispatch in `JobRunner`

- Introduce a shape-neutral protocol `AudioJobSending: Sendable` with the existing `send(job:provider:audioURL:apiKey:) async throws -> String` signature. `DefaultChatCompletionsAudioSender` and the new `DefaultElevenLabsScribeSender` both conform.
- `JobRunner` holds `handlers: [JobShape: any AudioJobSending]` (default = chat + scribe).
- `run(job:provider:shape:audioURL:)` gains a `shape: JobShape` parameter; it looks up `handlers[shape]` and throws `JobRunner.Error.unsupportedShape(JobShape)` for shapes with no handler (`transcriptionMultipart`, `geminiGenerateContent`).
- `AppCoordinator.runJob` resolves the shape from the provider's preset (`presets.preset(id: provider.presetID)?.shape`); a missing preset flashes a broken-provider failure, mirroring today's `providerMissing` path.

*Alternative considered:* `JobRunner` owns `PresetsStore` and resolves shape internally (keeps `run()`'s signature). Rejected to keep `JobRunner` free of a `PresetsStore` dependency and trivially unit-testable.

## Preset change

`presets.json`, `elevenlabs` entry:

- `suggestedModels`: `["scribe_v2", "scribe_v1"]` (drops the non-existent `scribe_v1_experimental`; `scribe_v2` is the "Scribe 2" model).
- `defaults`: unchanged (`{"diarize":"true"}`).

## Testing (SPM, fully offline)

- **`ElevenLabsScribeHandlerTests`**
  - `buildRequest`: endpoint URL, `POST`, `xi-api-key` header, multipart boundary present, body contains the `model_id` / `file` (with filename) / `diarize` parts; emits optional parts only when set.
  - `buildRequest` throws `missingModel` on empty `job.model`.
  - Response formatting: diarized sample → `Speaker 1:` / `Speaker 2:` labelled lines; non-diarized sample → plain `text`; `outputExt == "json"` → raw passthrough.
- **`JobRunnerTests`** (extend): routes `elevenLabsScribe` → scribe handler, `chatCompletionsAudio` → chat handler, and an unsupported shape throws `unsupportedShape`. Existing fixtures move from `ChatCompletionsAudioSending` to `AudioJobSending` + the new `shape:` argument.

## Files touched

- New: `Packages/AudioPipeline/Sources/AudioPipelineJobs/ElevenLabsScribeHandler.swift`
- New: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/ElevenLabsScribeHandlerTests.swift`
- Modify: `JobRunner.swift` (protocol generalization, handler map, `shape:` param)
- Modify: `ChatCompletionsAudioHandler.swift` (`DefaultChatCompletionsAudioSender` conforms to `AudioJobSending`)
- Modify: `JobRunnerTests.swift` (fixtures → `AudioJobSending`, `shape:` arg, dispatch tests)
- Modify: `Resources/presets.json` (`elevenlabs.suggestedModels`)
- Modify: `audio-pipeline/AppCoordinator.swift` (resolve shape, pass to `run`, handle missing preset)
