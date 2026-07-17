# Apple SpeechAnalyzer as a Local Transcription Engine — Design

**Date:** 2026-07-16
**Status:** Design (awaiting review)
**Companion:** [`docs/local-transcription-backend-research.md`](../../local-transcription-backend-research.md), [`2026-07-03-indicconformer-local-engine-design.md`](./2026-07-03-indicconformer-local-engine-design.md)

## Goal

Add Apple's `SpeechAnalyzer` / `SpeechTranscriber` (Speech framework, macOS 26+) as one more selectable model in the existing on-device catalog, behind the current `LocalTranscriptionEngine` protocol. It delivers three things the current catalog can't:

- **Zero download friction** — system-provided model, Apple-managed locale assets, no 200–700 MB app download.
- **Accuracy/latency** — benchmarked at 2.12% WER clean / 4.56% noisy (English, LibriSpeech), ~3× faster/sec than Whisper Small on an M2 Pro. (English/read-speech benchmark only; treat as directional, not a guarantee for noisy/accented/multi-speaker audio.)
- **Native word timestamps** — `SpeechTranscriber.Result` carries per-word `CMTimeRange`, so the diarized path works (unlike SenseVoice/Cohere, which fall back to plain).

### Non-goals (deferred)

- **Live streaming dictation.** `SpeechAnalyzer` is built for live audio (`start(inputSequence:)` + volatile results), but wiring it into the `DictationTranscriber` onPartial/onFinal seam is a separate, larger integration. Deferred. This spec is **batch only**: transcription Jobs and dictation-clip transcription, both of which already route through `LocalTranscriptionService` via `BatchTranscriber`.
- **Serving other clients** (the "Amanuensis Server" idea) — orthogonal, out of scope.

### Why this reverses the earlier "ruled out" call

On 2026-06-30 SpeechAnalyzer was ruled out as *the* local backend ("no model control, no tiering, no overnight-quality lever, can't serve other clients"). Those were objections to it being the whole backend. As *one engine alongside* Parakeet/Whisper/Cohere/IndicConformer, tiering and overnight-quality are already covered by the other models; this is purely additive.

## Architecture

Everything hangs off the existing `LocalTranscriptionEngine` seam. New/changed pieces:

| Piece | Change |
|---|---|
| `Packages/AudioPipeline/Sources/LocalTranscription/AppleSpeechEngine.swift` | **New.** Whole file `@available(macOS 26, *)`. `struct/final class AppleSpeechEngine: LocalTranscriptionEngine`. |
| `LocalModel.swift` → `LocalRunner` | **New case** `.appleSpeech`. |
| `LocalModel.swift` → `LocalModelCatalog.all` | **New row** (see Catalog row). |
| `LocalModel.swift` → availability | **New helper** `LocalModel.isAvailableOnThisOS` (or free func) returning `false` for `.appleSpeech` when `!#available(macOS 26)`, `true` otherwise. |
| `LocalTranscriptionService.swift` | Add `appleSpeech: (any LocalTranscriptionEngine)?` property + `.appleSpeech` case in `resolve`. |
| `AppCoordinator.swift` | Construct the engine behind `if #available(macOS 26, *)`; pass into the service (nil on <26). |
| `Amanuensis/UI/Models/ModelCardView.swift` | Installer variant for the per-language chips + footer (see Models UI). |
| `LocalModelsStore.swift` | Surface per-locale install state / progress for the installer (see Models UI). |

The keyless batch path (`localTranscription` `JobShape` → `LocalTranscriptionSender` → `LocalTranscriptionService`, with the `requiresAPIKey` carve-out) is **per-shape, not per-runner**, so Apple Speech inherits it with no sender changes.

## API mapping (verified against live macOS 26 docs)

`SpeechAnalyzer` = `final actor` (macOS 26.0+). `SpeechTranscriber` = `final class` (macOS 26.0+). `AssetInventory` = `final class` (macOS 26.0+).

| `LocalTranscriptionEngine` method | Speech (macOS 26) API |
|---|---|
| `transcribe(audioURL:model:language:)` | Build `SpeechTranscriber(locale:preset:)`; `SpeechAnalyzer(inputAudioFile:modules:[transcriber]…finishAfterFile:true)`; `try await analyzer.start(inputAudioFile:finishAfterFile:true)` (or `analyzeSequence`); drain `transcriber.results`, join `.text` of finalized results. |
| `transcribeTimed(...) -> [TimedWord]` | Same, with `.audioTimeRange` in the transcriber's `attributeOptions`. For each finalized `Result`, walk `result.text` (`AttributedString`) runs; each run carries `SpeechAttributes.TimeRangeAttribute` (`CMTimeRange`) → `TimedWord(text:, start: CMTimeGetSeconds(r.start), end: CMTimeGetSeconds(r.end))`. |
| `isDownloaded(_:)` | `SpeechTranscriber.installedLocales` contains the resolved locale (see language resolution). For the model as a whole: any of the default set installed, or treat "the currently-needed locale" — see Open questions Q1. |
| `installedBytes(_:)` | No per-locale byte API exists → return `0`. UI shows "System" instead of a size (see Models UI). |
| `download(_:progress:)` | `AssetInventory.assetInstallationRequest(supporting: [transcriber])` for the selected locale(s); drive `progress` from the request's `Progress`; then `AssetInventory.reserve(locale:)` each. |
| `delete(_:)` | `AssetInventory.release(reservedLocale:)` — relinquishes our reservation. The shared system asset may persist (we don't force-delete system assets). |
| `preload(_:)` | `SpeechAnalyzer.prepareToAnalyze(in:)`. |
| `unloadResident()` | Drop the retained analyzer/transcriber; nothing to unload from the ANE explicitly. |
| device support gate | `SpeechTranscriber.isAvailable`. |

## Language & asset management

`SpeechTranscriber` **requires an explicit locale and does not auto-detect.** Assets are per-locale and Apple-managed. This differs from every other catalog model (download once → handles all its languages). Resolution:

### Language resolution at transcribe time

`LocalModelCatalog.resolvedLanguage(forModel:requested:)` already normalizes the persisted language against `supportedLanguages`. For Apple Speech:

1. If `requested` is a supported locale code → use it.
2. Else fall back to the **system locale** (`Locale.current` mapped to a supported code via `SpeechTranscriber.supportedLocale(equivalentTo:)`).
3. Else `en-US`.

The catalog row leaves `defaultLanguage = nil` (broad model); the engine self-resolves system→en-US at runtime rather than forcing one code into the catalog.

### Install-on-demand (self-heal)

`transcribe`/`transcribeTimed` check `installedLocales` for the resolved locale; if absent, run `assetInstallationRequest` transparently before analyzing. So a transcription language the user never pre-installed still works — with a one-time install wait.

### The installer UI (per user's chosen UX)

Rather than a single opaque download or blind bulk install, the Apple Speech card **shows the supported languages and lets the user pick which to install**:

- Language list sourced from `SpeechTranscriber.supportedLocales` at runtime (~30 on macOS 26); each shows installed / not-installed from `installedLocales`.
- **Checkboxes**, pre-checked to the **intersection of `Locale.preferredLanguages` with `supportedLocales`** (the user's system-preferred languages). User can check/uncheck.
- **Download** installs the checked-but-not-installed set via `assetInstallationRequest(supporting:)` + `reserve(locale:)`; unchecking an installed locale calls `release(reservedLocale:)`.
- **`AssetInventory.maximumReservedLocales`** caps concurrent reservations. If the checked set would exceed it, the card surfaces the cap and blocks further checks rather than failing silently. (Install-on-demand at transcribe time reserves the needed locale, releasing the least-recently-used if at cap — see Open questions Q2.)

## Availability gating (macOS 26 vs deployment target 14.4)

App + SPM package both target **macOS 14.4**; the Speech API here is **macOS 26.0+**. Fencing:

- **Engine file** entirely `@available(macOS 26, *)`; `import Speech` at file scope is fine (only the new symbols are gated, and they're only touched inside the 26-only type).
- **Service** stores `appleSpeech: (any LocalTranscriptionEngine)?`. The existential erases the 26-only concrete type, so the property is legal on 14.4. `resolve(.appleSpeech)` returns it if non-nil, else throws (`unsupportedModel`, or a clearer "requires macOS 26" error — see Open questions Q3).
- **Composition root** constructs it only inside `if #available(macOS 26, *) { AppleSpeechEngine() } else { nil }`.
- **Catalog** row is present in `all` unconditionally; the two UI list sites (`ModelsView`, `ModelSelector`) filter out `.appleSpeech` when `!#available(macOS 26)` via `isAvailableOnThisOS`. Same runtime-fence pattern `GlassPanel.swift` already uses for Liquid Glass.

## Catalog row (proposed)

```swift
LocalModel(
  id: "apple-speech",
  displayName: "Apple Speech (System)",
  summary: "Built into macOS 26. No download; Apple-managed languages. Fast, private, on-device.",
  languages: "~30 languages (system-managed)",
  supportedLanguages: [/* hardcoded ~30 SpeechTranscriber locale codes; live list queried at runtime for the installer */],
  approxBytes: 0,              // "System" in UI, not "~0 bytes"
  runner: .appleSpeech,
  selector: "",               // unused; preset chosen in-engine
  recommended: false,         // Parakeet 110M stays the English default
  defaultLanguage: nil)       // engine self-resolves system → en-US
```

`supportedLanguages` is hardcoded (compile-time, must exist on 14.4 for the picker/`resolvedLanguage`); the installer's live language list comes from `SpeechTranscriber.supportedLocales` at runtime on 26+.

## Models UI changes

- `ModelCardView`: for `.appleSpeech`, `sizeText` shows **"System"** (not `~0 bytes`); the expandable language section becomes an **interactive installer** (checkable chips with per-locale installed state), and the footer's Download acts on the checked set. Reuses the existing `languagesExpanded` / `languageChips` scaffold.
- `LocalModelsStore`: extend `ModelState` (or add a sibling) to carry per-locale install state + install progress for this model, driven by `installedLocales` and the install request's `Progress`. Keep the change localized; other models are unaffected.

## Error handling

- `transcribe` maps Speech errors to `LocalTranscriptionError.transcriptionFailed(_)`.
- Locale not installable / asset unavailable → `modelNotDownloaded`-style message pointing at the installer.
- `SpeechTranscriber.isAvailable == false` (device unsupported despite OS) → clear "not available on this device."
- `transcribeTimed` producing no runs with time ranges → `timingsUnavailable(plainText:)` so the diarized path degrades to plain without a second pass (mirrors the existing contract).

## Testing

- **Service-level logic** (resolve dispatch, diarized fallback, availability nil-engine path) — unit-tested with the existing `FakeEngine`, no OS gate. Add a fake-backed test that `resolve(.appleSpeech)` throws when the engine is nil.
- **Real engine** — can only run on macOS 26 with the model available; **cannot run in the Claude Code sandbox** (asset dirs + `SpeechTranscriber.isAvailable`). Add a gated integration test (mirroring `IndicConformerIntegrationTests`) that `#available(macOS 26)`-guards and skips when unavailable. Runs via the xcode-build daemon (host is on macOS 26.3) or in-app.
- **App build** after SPM green, per CLAUDE.md.

## Open questions / risks

- **Q1 — model-level `isDownloaded`.** The protocol's `isDownloaded` is per-model, but Apple's assets are per-locale. Proposal: `isDownloaded` = "the resolved transcription locale is installed" (self-heal covers the rest). Confirm this reads sensibly in `ModelSelector`'s downloaded/greyed logic, or special-case Apple Speech to always-selectable (it self-heals).
- **Q2 — reservation cap policy.** If install-on-demand needs a locale while at `maximumReservedLocales`, release the least-recently-used reservation vs. surface an error. Needs the cap's actual runtime value to decide (likely small).
- **Q3 — error type for <26.** Reuse `unsupportedModel` or add a dedicated "requires macOS 26" `LocalTranscriptionError` case for a clearer message. Minor.
- **Q4 — daemon/CI SDK.** Building the engine needs the macOS 26 SDK (Xcode 26.x). CI is pinned (memory: Xcode 26.3) and the daemon host is 26.3, so the SDK is present; confirm the x86 CI leg doesn't choke on the 26-only file (it compiles — symbols are gated — but verify).
