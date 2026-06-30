# Local (on-device) transcription — backend & distribution research

> **Status:** research / design exploration (no code yet). Compiled 2026-06-30.
> **Goal:** add *on-device* (offline, private) speech-to-text to Amanuensis as a peer of
> the existing cloud connectors (ElevenLabs, Groq Whisper) — driven by a **tiered model
> lineup**, not a single model.
> **Decision frame (from the brief):**
> - Distribution must work for **both** Developer ID (direct, notarized) **and** the Mac
>   App Store — they diverge sharply on what a helper/plugin/download may do.
> - Two use-cases: **batch** transcription of finished recordings (the Jobs path) and a
>   forward-looking **realtime** dictation path.
> - Model tiers: a *fast/minimal* tier (English-only, European, Asian zh/ja/hi) that runs
>   on a **low-end 8 GB Apple Silicon MacBook** ("MacBook Neo"), plus *top-quality* heavy
>   models for "run overnight / when idle".
> - Priorities: **privacy / fully-offline, accuracy, speed** — *not* cloud cost.
> - Seed source the brief asked us to evaluate: Ivan Digital, *"MLX vs Core ML on Apple
>   Silicon"* — its central MLX-vs-CoreML JIT framing is **partly wrong**; see §3.

This doc is the on-device companion to `docs/realtime-streaming-asr-research.md` (which is
*cloud* streaming, explicitly out of scope here) and builds on the architecture seams that
doc already identified.

---

## 1. TL;DR

1. **Pick the backend by what's sandbox-safe and ANE-efficient, then let model availability
   refine it — not the other way round.** The seed article frames this as "MLX vs Core ML,
   and Core ML wins because MLX needs JIT." The *conclusion* (favour Core ML/ANE for the
   fast tier) is right; the *reason given* is wrong. **MLX does not JIT its standard kernels
   by default, and no on-device ASR backend needs `com.apple.security.cs.allow-jit`** (§3).
   The real reasons to prefer Core ML/ANE on an 8 GB Mac are **memory and power**, not
   entitlements.

2. **Default recommendation: link a Core ML / Apple-Neural-Engine backend *in-process* and
   download only the model *weights* as data.** Two mature, MIT-licensed, pure-Swift-SPM
   options exist today:
   - **WhisperKit** (Argmax) — the whole Whisper family pre-converted to Core ML,
     auto-downloaded from Hugging Face, ANE-accelerated, streaming-capable. Broadest
     language coverage (incl. Hindi at the larger tiers). Lowest integration friction.
   - **FluidAudio** — NVIDIA **Parakeet-TDT-0.6B** as Core ML on the ANE. Extremely fast
     and tiny (**~66 MB** working set on the ANE vs ~2 GB for the same model on the GPU via
     MLX), with **true** sliding-window streaming. **English-only (v2) / 25 European
     languages (v3) — no Chinese/Japanese/Hindi.**

3. **This in-process-backend + downloaded-weights split is the *only* architecture that
   works for both channels.** The Mac App Store forbids downloading **executable** code
   post-install (guidelines 2.5.2 / 2.4.5(iv)); model **weights are data** and stay
   downloadable on both channels via Apple's **Background Assets** framework. So: compile
   the runtime in, ship weights on demand. A **downloadable code plugin/`.bundle`** (the
   satellite-bundle idea in the SPM spec) is a **Developer-ID-only** option (§6).

4. **The model lineup drives one real fork: Hindi.** The fast Asian specialists
   (SenseVoice, Paraformer) are great at zh/ja but **do no Hindi**, and the best Chinese
   Zipformers have a non-commercial training-data problem. Only **two** stacks cover
   zh + ja + hi in one model with a clean commercial licence: **Whisper** (MIT) and the
   newly open-weighted **Qwen3-ASR** (Apache-2.0, released 2026-01-29). Qwen3-ASR already
   has an `mlx-swift` port — and it's the **one place MLX is genuinely the right call** for
   us (§4).

5. **Spike Apple's native `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26) first.** We
   target macOS 26.3. The system transcriber is on-device, ships **zero** third-party
   binary (perfect notarization/sandbox story), and covers zh/ja. If its quality is good
   enough for the lightweight tier, it could cover much of this for free. Hindi coverage is
   the unknown to test. **Cheap to evaluate; do it before committing to bundling anything.**

6. **Batch and streaming attach at *different* seams you already have.** Batch local
   transcription is a new `AudioJobSending` handler (file-in / text-out) — the
   `SonioxAsyncHandler` multi-step precedent proves local inference fits. Streaming is a new
   `DictationTranscriber` conformer (`onPartial`/`onFinal`) — exactly the seam the realtime
   doc and the dictation spec already call out. **Do not force streaming onto
   `AudioJobSending`** (§8).

---

## 2. Backend comparison (Apple Silicon, on-device ASR)

Four candidate runtimes. The headline split is **ANE vs GPU**: Core ML can target the Apple
Neural Engine (low power, tiny working memory); MLX and whisper.cpp/Metal run on the GPU
(more unified-memory pressure, more power). On an 8 GB machine that difference dominates.

| Backend | Compute | Swift integration | Sandbox + notarization | 8 GB fit | Notes |
|---|---|---|---|---|---|
| **Core ML / ANE** — WhisperKit, FluidAudio | **ANE** (+GPU/CPU fallback) | **Best.** Pure-Swift SPM, MIT, model auto-download | **Cleanest.** No special entitlement | **Best.** ~66 MB (Parakeet/ANE); compressed Whisper 0.5–0.6 GB | Encoder **and** decoder on ANE. The default. |
| **MLX** — mlx-swift, mlx-whisper, Qwen3-ASR-swift | GPU (Metal) | Good and improving; `mlx-swift` is first-party | **Fine.** No JIT by default (§3); no `allow-jit` | OK for ≤~1–2 GB models; GPU-resident | Needed when a model ships **only** as MLX (e.g. Qwen3-ASR). |
| **whisper.cpp / GGML Metal** — SwiftWhisper, whisper.spm | **GPU only** (ANE only via separate opt-in Core ML *encoder*) | Mature SPM (compiles from source) | **Fine.** No `allow-jit`; **but** runtime-shader fragility on macOS 26 unless you ship a precompiled `default.metallib` (§5) | Worse — model sits in unified memory, contends with system | Viable, entitlement-clean, but no ANE benefit and an OS-version maintenance burden. |
| **ONNX Runtime / sherpa-onnx** | CPU (MLAS) or CoreML EP → ANE | Roughest. C-bridged, community SPM | **Fine for JIT** (MLAS is precompiled); **library-validation** friction — Embed & Sign the dylib or add `disable-library-validation` | Depends on model | The way to run SenseVoice / Paraformer / Zipformer / IndicConformer if you need them. |

**Reported performance (treat as directional — vendor self-benchmarks, mostly *not* the
8 GB target):**
- FluidAudio Parakeet-TDT-0.6B on ANE: vendor-claimed **~110–190× real-time** (1 h audio in
  ~19 s) on **M4 Pro**; **~66 MB** working memory; ~1.69 % WER LibriSpeech test-clean (v2,
  English). The 190× number is M4 Pro, *not* a low-end Mac — discount accordingly.
- WhisperKit large-v3 (Core ML): roughly **15–30× real-time** on Apple Silicon; OD-MBP
  compression shrinks large-v3-turbo **1.6 GB → 0.6 GB** keeping **WER within ~1 %** of
  uncompressed (Argmax self-report, arXiv 2507.10860 — vendor benchmark, cite as such).
- whisper.cpp Metal: fast on Apple Silicon but **no clean 8 GB RTF/memory benchmark found**;
  GPU memory contention is a directional concern, not a measured number.

**A claim to *not* repeat:** that WhisperKit "matches the lowest cloud latency (0.46 s) and
best 2.2 % WER vs gpt-4o-transcribe / Deepgram / Fireworks" — that specific comparative
claim was adversarially **refuted (0-3)** in the research and should not be cited.

---

## 3. The MLX-vs-Core ML question, resolved (the seed article, corrected)

The seed article's load-bearing premise is that MLX relies on runtime Metal **JIT** and
therefore runs into the Hardened Runtime, while Core ML does not — so Core ML wins for a
notarized app. **The premise is mostly false, even though the practical conclusion (Core
ML/ANE is the better default for the fast tier) happens to be right for *other* reasons.**

- **MLX does not JIT its standard kernels by default.** It ships **pre-built** Metal
  kernels in its Metal library. `MLX_METAL_JIT` is an **opt-in build flag whose purpose is
  to *shrink* the library** by compiling kernels on first use; default builds (incl. pip
  wheels and `mlx-swift`) do not do this.
  (MLX docs: <https://ml-explore.github.io/mlx/build/html/install.html>)
- **`com.apple.security.cs.allow-jit` is about CPU W^X memory** (`mmap` `MAP_JIT`) for
  things like JavaScriptCore — *not* GPU shader compilation. The inference "a JIT/Metal
  backend would need `allow-jit`" was adversarially **refuted (0-3)**.
  (<https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.allow-jit>)
- **Even whisper.cpp's `newLibraryWithSource` runtime shader compilation is *not* "JIT" in
  the entitlement sense.** It hands MSL to the OS compiler service; the output is **GPU**
  machine code run by the GPU, not executable CPU pages in your process. No `allow-jit`
  needed. (High-confidence inference from the entitlement's documented scope + the Metal
  compile architecture + the empirical fact that notarized sandboxed Metal apps ship
  without it. The precompiled-`metallib` path sidesteps the question entirely.)

**So the entitlement story does not pick the backend.** What actually picks it:

1. **Power & memory on 8 GB** → ANE (Core ML) beats GPU (MLX / whisper.cpp). ~66 MB on the
   ANE vs ~2 GB on the GPU for the same Parakeet model is the whole argument.
2. **Model availability** → some models exist *only* as MLX (Qwen3-ASR today) or *only* via
   ONNX (SenseVoice). That, not JIT, is when "the model forces the backend."
3. **OS-version durability** → Core ML and ONNX-CoreML delegate to system frameworks;
   whisper.cpp's runtime-source-compile path is the one exposed to macOS-26 Metal stdlib
   breakage (§5).

---

## 4. Model lineup — tiered (this is what drives the choice)

### 4.1 The binding constraint is Hindi

Hindi separates the field. Whisper `tiny`/`base` are **unusable** for Hindi (>100 % WER);
Hindi needs a `small` floor and realistically `medium`/`large`. The strong, tiny Asian
specialists (**SenseVoice**, **Paraformer**) **do no Hindi at all**. The best Chinese
Zipformers are trained on **WenetSpeech (CC-BY-4.0 *non-commercial*)** — a real legal-gray
area for a paid app regardless of the weight licence. **Only Whisper (MIT) and Qwen3-ASR
(Apache-2.0) cover zh + ja + hi in one model with a clean commercial licence.**

### 4.2 Candidate matrix

| Model | zh / ja / hi | Size (params / on-disk) | Licence (commercial?) | Best Swift path | Friction |
|---|---|---|---|---|---|
| **Whisper small** | ✅ / ✅ / ⚠️ weak | 244 M / ggml-q5 ~190 MB, CoreML ~216 MB | **MIT** ✅ | **WhisperKit** | Lowest |
| **Whisper large-v3** (`v20240930`) | ✅ / ✅ / ✅ | 1.55 B / q5 ~1.08 GB, CoreML compressed 547–626 MB | **MIT** ✅ | **WhisperKit** | Lowest |
| **Whisper large-v3-turbo** | ✅ / ✅ / ✅ | 809 M / CoreML ~0.6 GB (OD-MBP) | MIT ✅ | WhisperKit | Lowest |
| **Parakeet-TDT-0.6B v2 / v3** | ❌ (Eng-only / 25 EU langs) | 0.6 B / ~0.6 GB; ~66 MB on ANE | code MIT; **NVIDIA weight licence — verify** | **FluidAudio** | Low |
| **Qwen3-ASR-0.6B** | ✅ / ✅ / ✅ | 0.6 B / GGUF-Q4 ~676 MB, MLX ~1.2 GB | **Apache-2.0** ✅ | **`mlx-swift` port** | Moderate (young) |
| **Qwen3-ASR-1.7B** | ✅ / ✅ / ✅ | 1.7 B / Q8 ~2.2 GB, MLX ~3.4 GB | Apache-2.0 ✅ | same port | Moderate |
| **SenseVoice-Small** | ✅ / ✅ / ❌ | 234 M / int8 ONNX ~226 MB | **Bespoke Alibaba licence** (commercial w/ attribution; non-OSI) | sherpa-onnx | Moderate + licence care |
| **Paraformer** (zh) | ✅ / ❌ / ❌ | ~220 M / int8 ~79 MB | Same bespoke licence | sherpa-onnx | Moderate |
| **sherpa Zipformer multi-zh-hans** | ✅ / – / – | 67–726 MB | weights Apache **but WenetSpeech non-commercial** | sherpa-onnx | **Legal risk** |
| **sherpa Zipformer ja (ReazonSpeech)** | – / ✅ / – | int8 ~148 MB | **Apache-2.0** ✅ | sherpa-onnx | Moderate |
| **IndicConformer-600M** (hi) | – / – / ✅ (~13 WER) | 600 M | **MIT** ✅ | ❌ NeMo→ONNX DIY | High |
| **NVIDIA Canary** | ❌ / ❌ / ❌ (EU/Eng) | 180 M–2.5 B | CC-BY-4.0 (canary-1b: **CC-BY-NC**) | ❌ no Apple path | **Drop** |
| **Moonshine** | ❌ (Eng; multiling "Flavors" no hi) | 27–61 M | MIT | ❌ no Swift pkg | Drop |

WER notes (lower better; zh/ja are character-level via Whisper's CJK normaliser, FLEURS):
Whisper `small` zh ~20.8 / ja ~12.0 / hi ~38.4; `medium` ~12.1 / ~7.1 / ~26.8; `large-v2`
~14.7 / ~5.3 / ~21.5 (large-v3 ~10–20 % better, no official per-language table). SenseVoice
beats large-v3 on **Chinese** (AISHELL-1 CER 2.96 vs 5.14) but **loses on Japanese**
(CV-ja 11.96 vs 10.34) — "beats Whisper" is true for zh, false for ja. Qwen3-ASR's
"beats large-v3 everywhere" is a **vendor claim, unverified** — A/B on real audio.

### 4.3 Recommended lineup

**Fast / minimal tier (8 GB "MacBook Neo"):**
- **English-only:** **FluidAudio Parakeet-TDT-0.6B-v2** (ANE, ~66 MB, ~1.7 % WER, true
  streaming) — fastest, tiniest, lowest power. Fall back to **Whisper `small.en`**
  (WhisperKit) if the NVIDIA weight licence is unacceptable.
- **European:** **Parakeet-TDT-0.6B-v3** (25 EU languages on the ANE) *or* **Whisper
  `small`** (MIT, broader). Parakeet for speed, Whisper for licence simplicity.
- **Asian (zh/ja/hi):** **Qwen3-ASR-0.6B via `mlx-swift`** — the only clean-licence
  lightweight model that does Hindi respectably in **one** model; fits 8 GB. Safe fallback:
  **Whisper `small`** (weak Hindi → bump to `medium` if Hindi matters). For zh/ja-only,
  SenseVoice-Small is the fastest, best-zh option but carries the bespoke licence and no
  Hindi.

**Quality / "run overnight" tier (zh + ja + hi):**
- **Primary: Whisper `large-v3` (`v20240930`) via WhisperKit** — MIT, mature, best Hindi of
  the Whisper line. On 8 GB use the **quantized/compressed** variant (~0.55–1.08 GB); never
  ship f16 large-v3 on an 8 GB Mac (~10 GB working set → swap/crash).
- **Challenger: Qwen3-ASR-1.7B** (Apache-2.0, native `mlx-swift`). If it wins on your audio,
  it collapses both tiers to one engine across zh/ja/hi.

**Two things worth a quick spike before committing:**
- **Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26):** native, zero binary, best
  sandbox story, on-device, zh/ja supported. Could cover the lightweight tier for free —
  Hindi is the unknown.
- The **`mlx-swift` Qwen3-ASR port** (`ivan-digital/qwen3-asr-swift`) appears to be from the
  **same author as the seed article** — active, ~macOS 15+, but its **sandbox/notarization
  behaviour is undocumented** and the llama.cpp GGUF audio path has open long-audio bugs.
  Verify before relying on it.

---

## 5. Sandbox + notarization — entitlements per backend

The app is sandboxed + Developer-ID-notarized today and may target MAS. Findings:

- **Core ML / ANE (WhisperKit, FluidAudio):** **no special entitlement.** This is the
  baseline.
- **MLX (mlx-swift / Qwen3-ASR):** **no `allow-jit`** in default builds (§3). Metal GPU
  access is normal. Weights cache to the sandbox container. *Verify* the specific Swift
  port under sandbox — it's young and undocumented on this point.
- **whisper.cpp / GGML Metal:** **no `allow-jit`.** Two caveats:
  - Its default path **runtime-compiles MSL** (`newLibraryWithSource`). On macOS 26 / Metal
    Toolchain 32023 this path is **fragile** — source-level Metal stdlib changes broke
    runtime compilation for MLX and ollama on Tahoe. **Mitigation: build with a precompiled
    `default.metallib` and ship it in the bundle** (load, don't compile). Runtime
    `newLibraryWithSource` *does* work on stock end-user macOS 26 without Xcode — the Metal
    toolchain download is a *build-time* concern only — but you're betting on each OS bump.
  - **`GGML_METAL_EMBED_LIBRARY` removes the filesystem lookup** for `ggml-metal.metal` (a
    real sandbox path bug otherwise) but **still runtime-compiles**. Prefer the metallib.
  - **SwiftWhisper / whisper.spm compile whisper.cpp *from source* into your signed
    binary**, so **library validation never bites** (unlike a prebuilt dylib).
  - Real notarized **and sandboxed** apps already ship it: **WhisperDesk**, **MacWhisper**
    (also on the MAS).
- **ONNX Runtime / sherpa-onnx:** **no JIT** (MLAS is precompiled; CoreML EP delegates to
  the ANE). **Library validation is the friction** — the prebuilt `libonnxruntime.dylib`
  ships unsigned, so either **Embed & Sign** it with your Developer ID (normal Xcode flow,
  then nothing extra) or add **`com.apple.security.cs.disable-library-validation`**. CoreML
  EP writes an `.mlmodelc` cache on first run — needs the (already-provided) sandbox cache
  dir.

**The big sandbox landmine for distribution:** the App Sandbox **prohibits spawning
arbitrary subprocesses**, so the common "ship `whisper-cli` as a sidecar and `exec` it"
pattern is a **hard blocker**. Every backend here must be **linked in-process** — which is
exactly what our handler architecture wants anyway (§8).

---

## 6. Distribution architecture — Developer ID vs Mac App Store

The core rule, verified against the App Review Guidelines (live-fetched 2026-06):

> **Model weights = data → downloadable on both channels. Executable backend code = only
> bundled-at-review for MAS; freely downloadable for Developer ID.**

- **MAS forbids downloading executable code** that adds/changes features (2.5.2; only a
  narrow educational exception) and bars downloading "standalone apps, kexts, additional
  code or resources" that significantly change the app (2.4.5(iv)). Enforced actively
  (Replit/Vibecode/"Anything" pulled 2026-03).
- **MAS requires the sandbox** (2.4.5(i)); **Developer ID does not** — the direct-download
  channel is materially freer.

Options, scored for our case:

| Option | What it is | MAS | Developer ID | Verdict |
|---|---|---|---|---|
| **(a) In-process library** | Backend linked into the app binary | ✅ | ✅ | **Recommended.** Works everywhere. WhisperKit/FluidAudio/whisper.cpp-from-source all fit. |
| **(b) Bundled XPC service / helper tool** | Helper embedded **at build time** | ✅ (non-privileged only) | ✅ | Fine if you want process isolation. Helper must be signed with **exactly two** entitlements: `app-sandbox` + `inherit` (any extra, e.g. Xcode-injected `get-task-allow`, crashes it). Privileged helpers: Dev ID only. |
| **(c) Separate bundled helper `.app`** | A second `.app` (LSUIElement) inside yours | ✅ (bundled at review) | ✅ | Allowed, but **cannot be *downloaded* post-install on MAS**. Heavier than (a)/(b) for little gain. |
| **(d) Downloaded code plugin / `.bundle`** | User downloads a loadable bundle after install (the SPM-spec satellite idea) | ❌ **forbidden** | ✅ | **Developer-ID-only.** This is the honest answer to "downloadable plugin." |
| **(e) On-demand model download** | Fetch **weights** to Application Support / via Background Assets | ✅ (data) | ✅ | **Recommended for the weights.** |

**Model download mechanics:**
- **Background Assets** is the idiomatic framework (macOS 13+, covers our 26.x target) with
  essential / prefetch / on-demand policies. macOS 26 adds **Apple-Hosted** packs (200 GB
  free in the Developer Program, accelerated ML-model update path **without** resubmitting
  the app) — **but Apple-hosting is App Store / TestFlight only.**
- For **Developer ID**, do **not** assume Background Assets self-hosting works — the
  "Apple-hosted *and* self-hosted dual path" claim was **refuted (1-2)**. Safest Dev-ID
  path: a plain **`URLSession` download into Application Support** (which is also what
  WhisperKit/FluidAudio already do from Hugging Face), or the older self-hosted
  `BADownloaderExtension` + your own CDN.

**Net distribution recommendation:** **(a) + (e)** — compile the Core ML/ANE backend into
the app, download weights as data. This single architecture clears both channels. Reserve
the **(d) downloadable `.bundle`** (e.g. a heavier MLX/Qwen3 engine) for the **Developer ID**
build only; for MAS, either compile that engine in (accepting binary size) or omit it.

---

## 7. Streaming vs batch on-device

- **Batch** (the Jobs path) is latency-tolerant and trivially served by any backend here.
- **Streaming** (live dictation) splits into two kinds:
  - **Chunked / VAD pseudo-streaming** over an encoder-decoder model (WhisperKit's
    `AudioStreamTranscriber`, ~0.45 s/word reported; whisper.cpp stream example). Latency is
    bounded by the chunk/window — fine, not great.
  - **True streaming** transducer/Zipformer models (Parakeet via FluidAudio's
    `SlidingWindowAsrManager`; sherpa Zipformer). Lower latency, partial results designed in
    — FluidAudio cites a Parakeet EOU variant at ~0.13 s **full-pipeline** in a third-party
    app (not an isolated ASR RTF; treat as directional).
- **For our realtime path, FluidAudio/Parakeet is the strongest on-device streaming engine**
  — but English/European only, so a multilingual live-dictation story still needs Whisper
  chunked-streaming or Apple's `SpeechTranscriber`. This mirrors the realtime-cloud doc's
  conclusion: streaming is its own seam with its own UX problem (the "commit window" for
  revising partials), not a reskin of batch.

---

## 8. How it fits Amanuensis (integration plan)

The codebase already has both seams. Batch and streaming attach in different places — keep
them separate.

### 8.1 Batch — a new `AudioJobSending` handler

The handler protocol is file-in / text-out and shape-agnostic:

```swift
// Packages/AudioPipeline/Sources/AudioPipelineJobs/AudioJobSending.swift:6
public protocol AudioJobSending: Sendable {
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String
}
```

`SonioxAsyncHandler` already does multi-step work (upload→poll→fetch) behind this one
method, so a local backend that loads a model, runs inference, and returns text fits cleanly.

Add-a-shape checklist (same as every existing connector):
1. New case in `JobShape` (`JobShape.swift:4`) — e.g. `localTranscription` — plus its
   `baseURLPathHint` / `requiresModel`.
2. New `fields` case in `FieldSpec.swift:30` (model picker, language, etc.).
3. `LocalTranscriptionHandler` enum + `DefaultLocalTranscriptionSender: AudioJobSending`.
4. Register it in `JobRunner.defaultHandlers` (`JobRunner.swift:16`).
5. A `presets.json` row with `"shape": "localTranscription"` and downloadable model ids in
   `suggestedModels` (the editor renders these as quick-fill buttons already).

`AppCoordinator.runJob` (`AppCoordinator.swift:319,354`) resolves the shape from the preset
and dispatches — **no change needed** there.

**Two carve-outs for a *keyless* local provider** (today everything assumes an API key):
- `JobRunner.run` fetches a Keychain key **before** calling the handler
  (`JobRunner.swift:39`) and would throw for a local provider with no key. Add a small
  branch: skip the key fetch when the shape is local (pass an empty string), or resolve a
  sentinel account.
- `ProviderEditorView.canSave` requires a non-empty API-key account
  (`ProviderEditorView.swift:84`). Relax it for keyless local providers.

### 8.2 Streaming — a new `DictationTranscriber` conformer

```swift
// Packages/AudioPipeline/Sources/DictationCore/DictationTranscriber.swift:6
// doc comment: "A future websocket/MLX engine emits interim text via onPartial."
```

A local streaming engine is a new conformer (`LocalTranscriber: DictationTranscriber`)
parallel to `BatchTranscriber` (`BatchTranscriber.swift:7`), emitting `onPartial`/`onFinal`.
The dictation spec (`docs/superpowers/specs/2026-06-18-dictation-design.md:349`) already
names the seam (`MLXTranscriber: DictationTranscriber`). **Do not** route streaming through
`AudioJobSending`.

### 8.3 Off-main inference (the concurrency rule)

The package uses default `MainActor` isolation with `NonisolatedNonsendingByDefault`, so a
bare `nonisolated async func` **inherits the caller's actor** — it does *not* move off-main
by itself. Inference must be **explicitly** dispatched. Mirror the existing precedents:
- `RecordingConversionService` — a `public actor` running heavy work on
  `Task.detached(priority: .utility)` (`RecordingConversionService.swift:47`).
- `AudioCompressor.compressToM4A`, wrapped in `Task.detached(.utility)` by its caller
  precisely for this reason (`TranscriptionMultipartHandler.swift:89`).

Put the model + inference loop behind a dedicated `actor` (or `Task.detached`), never a bare
`nonisolated async`.

### 8.4 Heavy-dependency isolation

The SPM module spec (`docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md`
§333-335) already plans a **separately-codesigned satellite `.bundle`** outside the umbrella
package so `AudioPipeline*` never takes an MLX/Core ML dependency. That intent holds — with
the **distribution caveat from §6**: a *downloaded* satellite bundle is **Developer-ID-only**.
For the MAS build, the backend must be **compiled into the app** (a Core ML/ANE backend like
WhisperKit/FluidAudio is light enough to link directly; an MLX engine is the one you'd gate
to Dev ID or compile in at a size cost).

### 8.5 Settings / model management UI

A new Section in `SettingsView.swift:61` (next to Dictation) is the natural home for model
download/management — a local backend has no API key, so it sidesteps the Keychain/provider
flow. Per-job model selection already works via the preset's `suggestedModels`.

---

## 9. Recommendation matrix

| Tier | Backend | Model | Licence | Channel fit | Notes |
|---|---|---|---|---|---|
| **Spike first** | Apple `SpeechAnalyzer` | system | — (OS) | both | Zero binary; best sandbox story; test zh/ja/hi quality. |
| **Fast — English** | FluidAudio (Core ML/ANE) | Parakeet-0.6B-v2 | code MIT; NVIDIA weights (verify) | both | ~66 MB, true streaming, fastest. Fallback Whisper `small.en` (MIT). |
| **Fast — European** | FluidAudio or WhisperKit | Parakeet-0.6B-v3 / Whisper `small` | MIT(-ish) | both | Parakeet=speed, Whisper=licence simplicity. |
| **Fast — Asian zh/ja/hi** | MLX (`mlx-swift`) | **Qwen3-ASR-0.6B** | **Apache-2.0** | **Dev ID** (download) / MAS (compile-in) | Only clean-licence light model doing Hindi. Verify sandbox. |
| **Quality — all langs** | WhisperKit (Core ML/ANE) | Whisper **large-v3** (quantized) | **MIT** | both | Overnight tier; never f16 on 8 GB. |
| **Quality — challenger** | MLX | Qwen3-ASR-1.7B | Apache-2.0 | Dev ID / MAS-compile | A/B vs large-v3; could unify both tiers. |
| **zh/ja specialist (optional)** | sherpa-onnx | SenseVoice-Small | bespoke Alibaba | both (Embed & Sign) | Best/fastest zh; no Hindi; keep licence text on file. |

**Phasing suggestion:**
1. **Spike** Apple `SpeechTranscriber` (free, may cover the light tier) **and** prove the
   batch seam end-to-end with **WhisperKit** (lowest friction, both channels).
2. Add **FluidAudio/Parakeet** for the fast English/European tier + the streaming
   `DictationTranscriber` conformer.
3. Add **Qwen3-ASR (MLX)** for the Asian tier — Dev-ID download first; decide MAS
   compile-in later.
4. Add **Whisper large-v3** as the overnight quality tier.
5. Optional: sherpa-onnx **SenseVoice** if Chinese accuracy becomes a headline feature.

---

## 10. Open questions / spikes before committing

1. **Apple `SpeechAnalyzer` quality** for zh/ja/**hi** on macOS 26.3 — could remove the need
   to bundle anything for the light tier. Cheapest, highest-leverage spike.
2. **Qwen3-ASR `mlx-swift` under App Sandbox + notarization** — undocumented; the engine's
   weights-cache, Metal access, and notarization all need a real test. Also verify its
   accuracy claims on representative zh/ja/hi audio.
3. **NVIDIA Parakeet *weight* licence** — confirm commercial-use terms (code is MIT/Apache;
   the model weights are the question) before shipping FluidAudio in a paid app.
4. **Cold-start / first-run Core ML compile latency and steady-state memory on a true 8 GB
   machine** — the 190×/M4-Pro figures don't represent the low-end target. Measure WhisperKit
   large-v3-turbo (0.6 GB) vs FluidAudio Parakeet on the actual floor hardware.
5. **whisper.cpp `default.metallib` packaging** — only needed if we adopt whisper.cpp; verify
   the precompiled-metallib build is sandbox-clean and survives a macOS point release.
6. **SenseVoice/FunASR licence** — non-OSI, HF tags self-contradict; keep the exact
   `MODEL_LICENSE` text on file if used. Avoid WenetSpeech-trained Chinese Zipformers in a
   paid app (non-commercial training data).

---

## Sources

**Backends & Swift integration**
- WhisperKit — <https://github.com/argmaxinc/WhisperKit> · Core ML weights
  <https://huggingface.co/argmaxinc/whisperkit-coreml> · OD-MBP paper (arXiv 2507.10860)
  <https://arxiv.org/pdf/2507.10860>
- FluidAudio — <https://github.com/FluidInference/FluidAudio> · Parakeet Core ML
  <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml> · ANE footprint
  <https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/>
- MLX build/JIT flag — <https://ml-explore.github.io/mlx/build/html/install.html> ·
  lightning-whisper-mlx (claims unverified) <https://github.com/mustafaaljadery/lightning-whisper-mlx>
- whisper.cpp — <https://github.com/ggml-org/whisper.cpp> · SwiftWhisper
  <https://swiftpackageindex.com/exPHAT/SwiftWhisper> · whisper.spm
  <https://github.com/ggerganov/whisper.spm> · GGML Metal loader
  <https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-metal/ggml-metal-device.m>
- sherpa-onnx — <https://github.com/k2-fsa/sherpa-onnx> · community SPM
  <https://swiftpackageindex.com/willwade/sherpa-onnx-spm> · ONNX Runtime CoreML EP
  <https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html>

**Models & licences**
- Whisper — <https://github.com/openai/whisper> · WER tables
  <https://cdn.openai.com/papers/whisper.pdf> · turbo
  <https://github.com/openai/whisper/discussions/2363>
- Qwen3-ASR — <https://github.com/QwenLM/Qwen3-ASR> · 1.7B
  <https://huggingface.co/Qwen/Qwen3-ASR-1.7B> · `mlx-swift` port
  <https://github.com/ivan-digital/qwen3-asr-swift> · GGUF
  <https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF>
- SenseVoice / FunASR — <https://github.com/FunAudioLLM/SenseVoice> · MODEL_LICENSE
  <https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE> · paper
  <https://arxiv.org/html/2407.04051v1>
- NVIDIA Canary — <https://huggingface.co/nvidia/canary-1b-v2> (canary-1b is CC-BY-NC) ·
  sherpa pretrained <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html> ·
  ReazonSpeech (ja, Apache) <https://huggingface.co/reazon-research/reazonspeech-k2-v2> ·
  WenetSpeech (non-commercial) <https://github.com/wenet-e2e/WenetSpeech> · IndicConformer
  <https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual>

**Sandbox / notarization / distribution**
- `allow-jit` entitlement —
  <https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.allow-jit>
  · Hardened Runtime <https://developer.apple.com/documentation/security/hardened-runtime>
- App Review Guidelines (2.5.2, 2.4.5) — <https://developer.apple.com/app-store/review/guidelines/>
- Embedding a helper tool in a sandboxed app —
  <https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app>
- Background Assets — <https://developer.apple.com/documentation/BackgroundAssets> · WWDC25 325
  <https://developer.apple.com/videos/play/wwdc2025/325/>
- Notarized+sandboxed whisper.cpp apps — WhisperDesk
  <https://github.com/PVAS-Development/whisperdesk> · MacWhisper
  <https://github.com/ggml-org/whisper.cpp/discussions/420>
- macOS 26 Metal runtime-compile breakage — MLX <https://github.com/ml-explore/mlx/issues/3337>
  · ollama <https://github.com/ollama/ollama/issues/15594>
- ONNX Runtime unsigned-dylib / library validation —
  <https://github.com/microsoft/onnxruntime/issues/16168>
