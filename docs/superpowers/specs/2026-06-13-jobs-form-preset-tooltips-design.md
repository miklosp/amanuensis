# Jobs form: provider-specific tooltips for prompt / context / vocabulary

Date: 2026-06-13
Status: Approved design, pending implementation

## Problem

The Jobs editor lets a user configure a transcription job against one of several
providers. The `prompt` / `context` / vocabulary fields behave very differently
per provider — and even per model — yet the form shows a single generic hint
keyed by wire shape (`JobShape.fields[*].help`). Several providers share one wire
shape (e.g. `transcriptionMultipart` is OpenAI Whisper, gpt-4o-transcribe, Groq,
Mistral, Cohere), so the current per-shape hint cannot be accurate for all of
them. The user wants accurate, provider-dependent constraint info surfaced as a
hover tooltip on the form.

## Goal

For each preset that exposes a prompt/context field, show an accurate,
provider-specific explanation of what that field does and its constraints, as a
hover tooltip (`info.circle` icon + `.help()`) next to the field label. The
existing short inline caption stays.

## Non-goals

- Not changing the per-shape inline `spec.help` captions.
- Not adding a prompt/vocabulary field to ElevenLabs Scribe (it has none).
- Not redesigning presets into (provider+model) endpoint configs (considered and
  rejected as a separate project — see Decisions).
- Not switching tooltip text off the free-text `model` string at runtime.

## Decisions (from brainstorming)

1. **Granularity: per-preset.** Constraint text lives on the preset, in
   `presets.json`, because the wire shape is shared by providers with different
   rules. Chosen over per-shape (inaccurate) and a `FieldSpec` refactor (overkill).
2. **Display: hover tooltip.** An `info.circle` icon next to the label carries
   the rich text via `.help()`. The always-visible inline caption (`spec.help`)
   is unchanged. Chosen over enriching the inline caption (clutters the form).
3. **Model granularity: split `openai-whisper` only.** Audit showed exactly one
   preset bundles models whose constraints genuinely differ (whisper-1 =
   ~224-token biasing; gpt-4o-transcribe = free instructions). Every other
   multi-model preset (groq, gemini, elevenlabs) has uniform constraints across
   its models. So we split just that one preset rather than redesign the model
   field. Keep the `openai-whisper` id for the whisper-1 half so existing saved
   Providers that reference it do not dangle.
4. **Auto-fill single-model presets.** When a selected preset has exactly one
   `suggestedModels` entry, pre-fill the `model` field on provider selection.

## Design

### 1. Data model — `Preset.fieldHelp`

Add to `Packages/AudioPipeline/Sources/AudioPipelineJobs/Preset.swift`:

```swift
public let fieldHelp: [String: String]?   // field key -> hover tooltip text
```

- Optional, so presets without it (e.g. ElevenLabs) decode unchanged.
- Codable is synthesized; the missing JSON key decodes to `nil`.
- The manual `init` gains `fieldHelp: [String: String]? = nil` (default at the
  end, after `docsURL`) so any direct call sites keep compiling.
- Keyed by `FieldSpec.key` (`"prompt"`, `"context"`).

### 2. `presets.json` — split + content

**Split `openai-whisper`:**

- `openai-whisper` — keep id; `displayName` → `"OpenAI Whisper"`;
  `suggestedModels` → `["whisper-1"]`; add `fieldHelp.prompt`.
- New `openai-gpt4o-transcribe` — `displayName` `"OpenAI gpt-4o-transcribe"`;
  shape `transcriptionMultipart`; baseURL `https://api.openai.com`;
  `suggestedModels` `["gpt-4o-transcribe","gpt-4o-mini-transcribe"]`;
  same `docsURL`; add `fieldHelp.prompt`.

**`fieldHelp` coverage** — one entry per preset that has a prompt/context field
(11 presets after the split; ElevenLabs excluded). Draft strings below; **every
string is to be verified against that preset's `docsURL` (and web docs) during
implementation — not shipped from memory.**

| Preset | Key | Draft tooltip (verify) |
|---|---|---|
| openai-chat-audio | prompt | Full instructions sent to the chat model with the audio (system+user). Real instructions, not keyword biasing. Bounded by the model's context window. |
| openai-compat-chat | prompt | Full instructions for the chat model alongside the audio. Limits depend on your endpoint's model. |
| openrouter | prompt | Full instructions for the routed chat model alongside the audio. Limits depend on the model you select on OpenRouter. |
| openai-whisper | prompt | whisper-1 treats this as a vocabulary/style bias, not instructions. Only the last ~224 tokens are used; include names/jargon spellings to nudge output. |
| openai-gpt4o-transcribe | prompt | gpt-4o-transcribe/-mini treat this as free-text instructions/context (e.g. "expect medical terms"). No 224-token cap like whisper-1; keep it concise. |
| groq-whisper | prompt | Groq runs Whisper; this is a ~224-token vocabulary/style bias (last 224 tokens used), not instructions. |
| mistral-voxtral | prompt | VERIFY whether Voxtral transcription honors a biasing prompt; state plainly if ignored. |
| cohere | prompt | VERIFY Cohere prompt support; note language code is required. |
| openai-compat-transcribe | prompt | Depends on your endpoint's model: Whisper-style = ~224-token vocabulary biasing; gpt-4o-style = instructions. |
| gemini | prompt | Free-text instructions/context for the model with the audio. Real instructions, not keyword biasing. Large context window. |
| soniox-async | context | Plain text is sent as `{text: ...}`. Or paste a Soniox context JSON object — only `general`/`text`/`terms`/`translation_terms` are kept (other keys stripped). Biases recognition toward names/jargon. VERIFY size cap. |

### 3. Auto-fill model

In `audio-pipeline/UI/Jobs/JobEditorView.swift`, where `model` is reset on
provider change:

- `editorForm` `onChange(of: providerID)` (reset branch, when `oldShape != newShape`).
- `repairPane` `onChange(of: providerID)` (always-reset branch).

Replace `model = ""` with: if the new preset has exactly one `suggestedModels`
entry, set `model` to it; otherwise `""`. This auto-fills single-model presets
(voxtral, cohere, soniox, openai-chat-audio, and now openai-whisper) and leaves
multi-model presets empty for the user to choose. Same-shape provider switches
still preserve the typed model (unchanged behavior — no clobbering).

### 4. UI — tooltip icon

In `audio-pipeline/UI/Jobs/JobFieldFormView.swift`:

- Add a stored `let fieldHelp: [String: String]` (default-passed as
  `preset?.fieldHelp ?? [:]` from `JobEditorView`).
- In the `field(_:)` helper, wrap the label `Text` in an `HStack` that appends,
  when `fieldHelp[spec.key]` is non-empty:
  `Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary).help(tooltip)`.
- Mirror the same icon in the `.checkbox` branch's label `VStack` (so any future
  checkbox with a tooltip works), though no checkbox field carries one today.
- The inline `spec.help` caption rendering is untouched.

`JobEditorView` already resolves `preset: Preset?` (line 40) and passes `shape`
to `JobFieldFormView` (line 142); add the `fieldHelp:` argument there.

### Data flow

```
presets.json (fieldHelp)
   -> PresetsStore.loadBundled() decodes Preset.fieldHelp
   -> JobEditorView.preset?.fieldHelp
   -> JobFieldFormView(fieldHelp:)
   -> info.circle + .help(text) next to matching field labels
```

## Content sourcing

Each tooltip string is verified against the preset's `docsURL` before shipping;
where a provider's behavior is unclear from docs (Voxtral, Cohere prompt
support; Soniox context size cap), confirm via the live docs and state the real
behavior — including "this field is ignored" when that's the truth.

## Testing

SPM (deterministic, `AudioPipelineJobsTests`):

1. `PresetsStore.loadBundled()` still succeeds with the new `fieldHelp` keys.
2. **Coverage invariant:** for every loaded preset, for every field in
   `preset.shape.fields` whose key is in `{"prompt","context"}`, assert
   `preset.fieldHelp?[key]` is present and non-empty. Guards against shipping a
   prompt/context field with no tooltip.
3. The split is present: `preset(id: "openai-whisper")?.suggestedModels == ["whisper-1"]`
   and `preset(id: "openai-gpt4o-transcribe")` exists with the two gpt-4o models.

App target: after SPM tests pass, rebuild the app target (per CLAUDE.md) — the
`JobFieldFormView` / `JobEditorView` changes are app-side and `swift test` does
not compile them. The hover tooltip itself is verified visually.

## Migration notes

- Keeping the `openai-whisper` id means saved Providers pointing at it remain
  valid; they narrow from "whisper + gpt-4o-transcribe" to "whisper-1". A
  Provider that was using gpt-4o-transcribe under the old preset keeps working
  (model is stored on the Job, sent as-is) but won't get the gpt-4o tooltip
  unless re-pointed at the new preset. Acceptable for this dev-stage app.

## Files touched

- `Packages/AudioPipeline/Sources/AudioPipelineJobs/Preset.swift` — add `fieldHelp`.
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json` — split + content.
- `audio-pipeline/UI/Jobs/JobFieldFormView.swift` — icon + `.help`, `fieldHelp` input.
- `audio-pipeline/UI/Jobs/JobEditorView.swift` — pass `fieldHelp`, auto-fill model.
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/` — new coverage test (file
  TBD; likely a `PresetsStoreTests` or `PresetFieldHelpTests`).
