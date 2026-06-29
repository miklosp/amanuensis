# Add Cohere and Reson8 transcription providers

**Date:** 2026-06-29
**Status:** Approved (design)

## Goal

Add two speech-to-text providers to the Jobs layer:

1. **Cohere** — `cohere-transcribe-03-2026`. A preset already exists but is **broken**: it
   was added speculatively on the `transcriptionMultipart` shape, which hardcodes the
   `/v1/audio/transcriptions` path, while Cohere's real endpoint is `/v2/...`. "Adding"
   Cohere means fixing it.
2. **Reson8** — prerecorded speech-to-text. A genuinely new wire shape (raw-audio body +
   query-param options), no existing preset.

Both should appear automatically in the provider/preset picker (data-driven) and run end to
end. No new HTTP transport concepts are introduced — both reuse patterns the codebase already
has (`transcriptionMultipart` for Cohere, `deepgramListen`-style raw body for Reson8).

## Background: how providers work today

- A **`Preset`** (data, `Resources/presets.json`) pins a **`JobShape`** plus base URL,
  suggested models, default fields, and UI help text. Presets are loaded by `PresetsStore`
  and listed in the provider editor.
- A **`JobShape`** (enum) maps 1:1 to a code-level **handler** conforming to
  `AudioJobSending` (`send(job:provider:audioURL:apiKey:) -> String`). Handlers are
  registered in `JobRunner.defaultHandlers`.
- `JobShape` also carries `baseURLPathHint` (shown in the provider editor) and `fields`
  (`[FieldSpec]`, drives the Job editor's Parameters form).
- The convention is **one shape per wire-level difference**. Adding a provider that differs
  in path/auth/body/response gets its own shape + handler.
- API keys live in the Keychain, referenced by `Provider.apiKeyRef`; `JobRunner` fetches the
  key and passes it to the handler.

## Wire facts (from each provider's API reference)

### Cohere — `POST https://api.cohere.com/v2/audio/transcriptions`
- Auth: `Authorization: Bearer <key>`
- Body: `multipart/form-data` — `model` (required), `language` (**required**, ISO-639-1),
  `file` (required), `temperature` (optional, 0–1)
- **No** `prompt` parameter — Cohere ignores any prompt/biasing.
- Response: `application/json`, transcript at top-level `text` (`{"text": "..."}`).
- Identical to the `transcriptionMultipart` shape **except** the `/v2` path and that
  `language` is mandatory.

### Reson8 — `POST https://api.reson8.dev/v1/speech-to-text/prerecorded`
- Auth: `Authorization: ApiKey <key>` for static server-to-server keys (the Bearer/token-
  exchange path is for browser clients and is not used here — fits the app's static-key
  Keychain model).
- Body: **raw audio bytes**, `Content-Type: application/octet-stream`.
- Options: **query parameters** — `language` (optional, auto-detects), `diarize` (bool),
  `max_speakers`, `custom_model_id` (optional), plus `encoding`/`sample_rate`/`channels`/
  `include_*`/`patterns` (not exposed — see YAGNI below).
- **No required model.** A server default is used unless `custom_model_id` is given.
- Response: `application/json`, transcript at top-level `text`. When `diarize=true`, a
  `segments[]` array is present, each segment carrying `text` and `speaker_id` (0-indexed).
- Structurally the same family as the existing Deepgram handler (raw body + query params),
  but different path, auth header, response schema, and no required model.

## Design

### Part 1 — Cohere → new `cohereTranscribe` shape

Cohere gets its own shape (matching the codebase convention) but **reuses the existing
multipart handler's request/transport code via a path parameter** — no copy of the
multipart-building, compression, parsing, or timeout logic.

| File | Change |
|---|---|
| `JobShape.swift` | `+ case cohereTranscribe`; `baseURLPathHint → "/v2/audio/transcriptions"`. |
| `FieldSpec.swift` | `+ case .cohereTranscribe`: `language` (`.language`, **required: true**), `temperature` (`.number`, optional). No `prompt` field. |
| `TranscriptionMultipartHandler.swift` | Add a `path:` parameter to `buildRequest(...)` and `send(...)`, **defaulting to `"/v1/audio/transcriptions"`** so all existing callers stay byte-identical. |
| `CohereTranscribeHandler.swift` (new) | `DefaultCohereSender: AudioJobSending` that delegates to `TranscriptionMultipartHandler.send(..., path: "/v2/audio/transcriptions")`. Reuses the 24 MB compression cap, the `{"text"}` parser, and the 600 s timeout unchanged. |
| `JobRunner.swift` | Register `.cohereTranscribe: DefaultCohereSender()` in `defaultHandlers`. |
| `presets.json` | cohere entry: `shape → "cohereTranscribe"`; remove the now-dead `fieldLabels`/`fieldHints`/`fieldHelp` for `prompt`; keep `baseURL: "https://api.cohere.com"`, `suggestedModels: ["cohere-transcribe-03-2026"]`, `defaultOutputExt: "txt"`, `docsURL`. |

Notes:
- `language` flows through the shared `buildRequest` automatically (it already copies
  `language` from `job.fields`). Marking it `required` in `FieldSpec` enforces it at the Job
  editor's Save gate; the handler does no field validation (same as today).
- `temperature` likewise flows through the shared optional-fields loop.
- `response_format` is not a Cohere parameter and is absent from the Cohere `FieldSpec`, so
  `parseResponse` receives `nil` and takes the default JSON path (`{"text"}` → string).

### Part 2 — Reson8 → new `reson8Prerecorded` shape

A new handler modeled on `DeepgramListenHandler` (raw body + query params), with Reson8's
path, auth, and response schema.

| File | Change |
|---|---|
| `JobShape.swift` | `+ case reson8Prerecorded`; `baseURLPathHint → "/v1/speech-to-text/prerecorded"`. Also add `var requiresModel: Bool` (see Part 3). |
| `FieldSpec.swift` | `+ case .reson8Prerecorded`: `language` (`.language`, optional — auto-detects), `diarize` (`.checkbox`, optional), `max_speakers` (`.number`, optional). |
| `Reson8PrerecordedHandler.swift` (new) | See below. |
| `JobRunner.swift` | Register `.reson8Prerecorded: DefaultReson8PrerecordedSender()`. |
| `presets.json` | `+ reson8` entry: `shape: "reson8Prerecorded"`, `baseURL: "https://api.reson8.dev"`, `suggestedModels: []`, `defaults: {}`, `defaultOutputExt: "txt"`, `docsURL`, `fieldHelp` for `diarize`/`max_speakers`. |

`Reson8PrerecordedHandler` (mirrors `DeepgramListenHandler`):
- `buildRequest`: `POST` to `{baseURL}/v1/speech-to-text/prerecorded` with
  `URLComponents` query items for `language`/`diarize`/`max_speakers` (copied from
  `job.fields` when present & non-empty). **No model is sent** and there is **no
  `missingModel` guard** (Reson8 has no required model; `custom_model_id` is not exposed).
  Header `Authorization: ApiKey <key>`; `Content-Type: application/octet-stream`; raw audio
  bytes as the body.
- `format(data:outputExt:)`: `json` mode → pretty-print the raw response (sorted keys), like
  Deepgram. Otherwise decode a `Response { text: String; segments: [Segment]? }` where
  `Segment { text: String; speaker_id: Int? }`. When `segments` exist and at least one
  carries a `speaker_id`, build `Speaker N: …` lines (first-seen speaker order, mirroring
  Deepgram's `labelledTranscript`); otherwise return the top-level `text`. Any drift in the
  optional `segments` array degrades to the flat `text` rather than failing.
- `requestTimeout = 600`; dedicated `URLSession`; `SendError` (`httpError`/
  `malformedResponse`) conforming to `LocalizedError` with a `"Reson8 HTTP <status>: …"`
  message for the in-app Logs view.
- `DefaultReson8PrerecordedSender: AudioJobSending` adapts the static `send`.

**No compression for Reson8.** Reson8 documents no upload size cap, so we mirror Deepgram and
send the raw audio untouched (no `prepareUpload`/24 MB path). Assumption: if Reson8 rejects
large uploads in practice, revisit by adding the compression path. (See
`project_groq_whisper_25mb_limit` for the precedent on the multipart side.)

### Part 3 — "no model" support in the Job editor

The Model field is hardcoded in `JobEditorView` (a `TextField` in the General section,
`:110-120`) and `canSave` requires `!model.isEmpty` (`:164`). Reson8 needs no model, so:

- Add `var requiresModel: Bool` to `JobShape` — `true` for every existing shape,
  `false` for `reson8Prerecorded`. Lives next to `baseURLPathHint`/`fields` (a property of
  the wire shape).
- `JobEditorView`: render the Model row only when `preset.shape.requiresModel`; relax
  `canSave` to require a non-empty model only when `preset.shape.requiresModel`.

Reson8's optional `custom_model_id` is intentionally **not** exposed (YAGNI). If needed later,
add it as an optional `.text` `FieldSpec` field and send it as a query param — no shape change.

## YAGNI / scope boundaries

- Reson8 query params beyond `language`/`diarize`/`max_speakers` (`encoding`, `sample_rate`,
  `channels`, `include_timestamps`, `include_words`, `include_language`,
  `include_confidence`, `custom_model_id`, `patterns`) are not exposed. We upload a
  container-framed FLAC/M4A, so `encoding`/`sample_rate`/`channels` auto-detect; the rest are
  not needed for plain-text/diarized-text output.
- The "version belongs in the baseURL" refactor (uniform path handling across all multipart
  providers) was considered and rejected: it would require migrating already-persisted user
  `Provider` records, which is broader and riskier than this task warrants.
- Reson8's Bearer/token-exchange auth path (browser clients) is out of scope; static
  `ApiKey` auth is the only mode used.

## Testing

SPM Swift Testing suites under `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/`:

- **`CohereTranscribeHandlerTests`** (or extend the multipart tests): request targets
  `{base}/v2/audio/transcriptions`; `Authorization: Bearer`; multipart body carries
  `model` + `language` + `temperature` when set; `{"text": "..."}` parses to the transcript.
- **`Reson8PrerecordedHandlerTests`** (mirrors `DeepgramListenHandlerTests`): `POST` to
  `{base}/v1/speech-to-text/prerecorded`; `Authorization: ApiKey`;
  `Content-Type: application/octet-stream`; raw body equals the audio bytes; query items map
  `language`/`diarize`/`max_speakers`; **empty model is allowed (no throw, no model sent)**;
  response parsing — plain `{"text"}` → text, diarized `segments[]` → `Speaker N:` lines,
  `json` output mode → pretty-printed raw.
- **`PresetsStoreTests`**: add `reson8` to the expected preset IDs; assert
  `cohere` preset's `shape == .cohereTranscribe`.
- **`JobShape` property test** (cheap): iterate `JobShape.allCases` and assert
  `requiresModel == false` only for `reson8Prerecorded`.
- Exhaustiveness of `baseURLPathHint`, `fields`, and `requiresModel` switches is compiler-
  enforced for the new cases.

After SPM tests pass, **rebuild the app target** (SPM green ≠ app compiles):
`swift test --disable-sandbox --package-path Packages/AudioPipeline`, then the
`scripts/xcode-build-helper.sh` Debug build.

## Sequencing

1. Create branch `feat/cohere-reson8-providers`.
2. Cohere: handler `path:` param → `cohereTranscribe` shape + `FieldSpec` → `DefaultCohereSender`
   → `JobRunner` registration → preset edit. Tests.
3. Reson8: `reson8Prerecorded` shape + `FieldSpec` + `requiresModel` → handler →
   `JobRunner` registration → preset add. Tests.
4. Job editor: conditional Model row + `canSave` relaxation.
5. `swift test`, then app-target rebuild.

## Risks

- **Reson8 response schema** is taken from its API reference, not exercised against a live
  key. The parser is defensive (unknown keys ignored; missing `segments` → flat `text`), so a
  minor schema mismatch degrades gracefully rather than crashing; a major one surfaces as a
  `malformedResponse` in the Logs view with the raw body.
- **Reson8 upload limits** unknown (see no-compression note).
- No UI code changes are needed for the picker (data-driven); the only UI change is the
  conditional Model field.
