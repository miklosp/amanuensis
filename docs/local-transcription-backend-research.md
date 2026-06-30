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
>
> **Update 2026-06-30 (post-review):** Apple's native `SpeechAnalyzer`/`SpeechTranscriber`
> is **ruled out** — no model control, no tiering, no overnight-quality lever, can't serve
> other clients. And "sidecar" is clarified to mean a **standalone "Amanuensis Server"** (an
> independent local HTTP/WS daemon), *not* a bundled helper or a downloaded plugin. That
> adds an architecture **option** to weigh (not a new default) — see §6.1. Measured bundle
> sizes in §2.1.
>
> **Update 2 (2026-06-30):** Core ML's on-device catalog is broader than first credited —
> **FluidAudio** runs the Asian specialists (Parakeet-ja, SenseVoice/Paraformer for zh) and
> **WhisperKit** covers Hindi, all Core ML/ANE in-process. **MLX is no longer required** for
> any requested tier (§2.2), which also defuses the MLX-size / server-to-avoid-MLX argument.

This doc is the on-device companion to `docs/realtime-streaming-asr-research.md` (which is
*cloud* streaming, explicitly out of scope here) and builds on the architecture seams that
doc already identified.

---

## 1. TL;DR

1. **Pick the backend by ANE-efficiency and model availability — not by JIT.** The seed
   article says "MLX needs JIT, Core ML doesn't, so Core ML wins." The *conclusion* (Core
   ML/ANE is the better default for the fast tier) is right; the *reason* is wrong. **MLX
   does not JIT its standard kernels by default, and no on-device ASR backend needs
   `com.apple.security.cs.allow-jit`** (§3). What actually decides it is **memory/power on
   8 GB** (ANE ≫ GPU) and **which backend a given model ships for**.

2. **Light tiers → a Core ML / ANE backend linked *in-process*; download only the model
   *weights* as data.** Two mature, MIT-licensed, pure-Swift-SPM options: **WhisperKit**
   (whole Whisper family, broadest languages incl. Hindi) and **FluidAudio** (NVIDIA
   Parakeet-TDT-0.6B, ~66 MB on the ANE, true streaming, but English/European only). Core
   ML is a **system framework → ~0 MB of frameworks + ~1–4 MB of Swift code** (§2.1).

3. **Heavy MLX placement turned out to be a non-problem — Core ML covers everything.** Per
   §2.2, **WhisperKit + FluidAudio** run the whole requested lineup (English, European, zh,
   ja, Hindi) on the Core ML/ANE path **in-process at ~1–4 MB**, so **MLX is not required**.
   That defuses the ~140 MB bundle / "where does MLX live" / "host MLX in a server" thread
   entirely (MLX adds a 119.6 MB metallib that, on MAS, can't be slimmed by a later download —
   §2.1, §6.2 — but you simply don't need MLX). MLX stays an *optional* niche: only if you
   prefer the prebuilt MLX Qwen3 over a hand-written Core ML harness.

4. **The split that matters: data vs executable code.** MAS forbids the app
   downloading/executing new *code* (2.5.2 / 2.4.5(iv)); model **weights are data** and stay
   downloadable on both channels (Background Assets). A **downloaded code plugin/`.bundle`**
   is **Developer-ID-only**; a standalone server is an alternative way to keep heavy code off
   the app (§6.1). In-process Core ML works on both channels and adds ~0 MB of frameworks
   (§2.1).

5. **Per-language models (user's call) — so no single zh+ja+hi model is needed, and Qwen3-ASR
   drops out.** zh → SenseVoice/Paraformer, ja → Parakeet-ja (both FluidAudio, fast), hi →
   **Whisper via WhisperKit** (vanilla `large-v3` now, or convert a **Hindi-finetuned Whisper**
   for better WER — WhisperKit runs any Whisper checkpoint). All Core ML/ANE, in-process
   (§2.2, §4.3).

6. **Batch and streaming attach at *different* seams you already have.** Batch = a new
   `AudioJobSending` handler *or* (server variant) a localhost provider — `SonioxAsyncHandler`
   proves multi-step local work fits. Streaming = a `DictationTranscriber` conformer
   (`onPartial`/`onFinal`). **Do not force streaming onto `AudioJobSending`** (§8).

---

## 2. Backend comparison (Apple Silicon, on-device ASR)

Four candidate runtimes. The headline split is **ANE vs GPU**: Core ML can target the Apple
Neural Engine (low power, tiny working memory); MLX and whisper.cpp/Metal run on the GPU
(more unified-memory pressure, more power). On an 8 GB machine that difference dominates.

| Backend | Compute | Swift integration | Sandbox + notarization | 8 GB fit | Notes |
|---|---|---|---|---|---|
| **Core ML / ANE** — WhisperKit, FluidAudio | **ANE** (+GPU/CPU fallback) | **Best.** Pure-Swift SPM, MIT, model auto-download | **Cleanest.** No special entitlement | **Best.** ~66 MB (Parakeet/ANE); compressed Whisper 0.5–0.6 GB | Encoder **and** decoder on ANE. The default. |
| **MLX** — mlx-swift, mlx-whisper, Qwen3-ASR-swift | GPU (Metal) | Good and improving; `mlx-swift` is first-party | **Fine.** No JIT by default (§3); no `allow-jit` | OK for ≤~1–2 GB models; GPU-resident | Needed when a model ships **only** as MLX (e.g. Qwen3-ASR). **~140 MB bundle cost (§2.1).** |
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

### 2.1 Bundle-size cost of each runtime (measured)

How many MB each runtime adds to a **notarized arm64 app bundle, excluding model weights**
(weights download separately). Numbers below were **measured** on 2026-06-30 by building the
Swift packages / inspecting the official release artifacts and the Mach-O binaries.

| Runtime | MB added to arm64 bundle (no models) | Framework? | Detail |
|---|---|---|---|
| **Core ML — WhisperKit** | **~1.2 MB** (Swift code) | Core ML/ANE/Accelerate = **system → 0** | `WhisperKit` + `ArgmaxCore`, `__TEXT`+`__DATA` of release build |
| **Core ML — FluidAudio** | **~3.5 MB** (Swift code) | system → 0 | release-build code size |
| **whisper.cpp / GGML Metal** | **~2.5 MB** | bundled | single arm64 binary incl. a **0.58 MB** embedded `__ggml_metallib` |
| **ONNX Runtime (CoreML EP)** | **~28 MB** dylib | bundled | prebuilt full build; a reduced custom build can be single-digit MB |
| **MLX (mlx-swift)** | **~140 MB** uncompressed (~40 MB compressed) | **bundled — not a system framework** | `libmlx` 20.6 MB + **`mlx.metallib` 119.6 MB** + ~2–4 MB Swift wrapper (est.) |

**Bottom line:** including **Core ML costs essentially nothing** (system frameworks + ~1–4 MB
code). Including **MLX costs ~140 MB on disk** (~40 MB compressed), **~35–100× the Core ML
path**, almost all of it the **119.6 MB prebuilt `mlx.metallib`**. The only lever to shrink
it is a custom core build with `MLX_METAL_JIT=ON` (drops the metallib, at a first-run
kernel-compile cost of a few hundred ms to a few seconds) — and that is *not* the default
SwiftPM `mlx-swift` dependency. **This size gap is a key input to *where* an MLX engine should live — bundled, a
Developer-ID plugin, or a separate server (§6) — not to whether MLX is sandbox-legal (it
is).**

### 2.2 The Core ML ASR catalog is broader than WhisperKit (this revises the MLX story)

**Correction to the first draft.** I treated Core ML ASR as "WhisperKit (Whisper) + FluidAudio
(Parakeet)" and routed the Asian tier to MLX/sherpa-onnx. That undersold it. **FluidAudio is a
general Core ML/ANE audio SDK** (MIT, 800k+ downloads, already shipping in Mac App Store apps)
that runs a large model zoo on the ANE — including the Asian specialists. Turnkey,
SDK-supported ASR models today:

| Model (FluidAudio) | Langs | Speed / notes | Licence |
|---|---|---|---|
| Parakeet TDT v2 / v3 / CTC-110M | EN / 25 EU / small | very fast on ANE | NVIDIA (verify) |
| **Parakeet TDT Japanese** | **ja** | 6.85 % CER JSUT, 10.8× RTF | NVIDIA (verify) |
| **SenseVoiceSmall** | zh + 50 langs (yue/ja/ko/en) | non-autoregressive, fast | **`license: other`** (FunASR) |
| **Paraformer-large** | **zh** | non-autoregressive Mandarin | bespoke FunASR |
| Cohere Transcribe | 14 (incl **ja/zh/ko/vi**) | 1.8 GB INT8, 35 s cap | Cohere (verify) |
| **Nemotron Streaming Multilingual** | en/es/fr/it/pt/de/**zh/ja** + auto | **true streaming**, 0.6B | NVIDIA |
| Parakeet EOU / Nemotron Streaming EN | en | ultra-low-latency streaming | NVIDIA |

**What changes:** the **Asian tier (zh, ja) is Core ML/ANE in-process** via FluidAudio — no
MLX, no sherpa-onnx, no server needed. **Hindi** stays in the same in-process Core ML family
via **Whisper / WhisperKit** (MIT). So **WhisperKit + FluidAudio cover English, European, zh,
ja, and hi — all Core ML/ANE, ~1–4 MB, both channels, no special entitlement.**

**A single model doing everything incl. Hindi isn't needed** — the brief allows one model per
language (zh/ja are the specialists above; Hindi is its own model, §4.3). The would-be
single-model option, **Qwen3-ASR**, has a Core ML build
(`FluidInference/qwen3-asr-0.6b-coreml`, Apache-2.0, zh/ja/**hi**/30+ langs, int8 ~0.7 GB) but
is in FluidAudio's **"Evaluated / Not Supported"** list (autoregressive, **~2.8–4.5× RTF**,
needs a hand-written harness), so it drops out for now.

**Net: MLX is no longer required for any requested tier.** Its only remaining draw is the
prebuilt MLX Qwen3 build over a hand-written Core ML harness — niche. The §6 "where does MLX
live / host it in a server to dodge 140 MB" discussion is therefore **moot for model
coverage**; the server (§6.1) now stands purely on its *other* merits (multi-client,
decoupling, independent updates).

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
3. **Bundle size** → MLX adds ~140 MB (§2.1); Core ML adds ~0. A factor in *where* an MLX
   engine lives (bundle / Dev-ID plugin / server) — not in whether MLX is sandbox-legal.
4. **OS-version durability** → Core ML and ONNX-CoreML delegate to system frameworks;
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

> Swift-path note: several "sherpa-onnx" entries below now have a **turnkey Core ML/ANE path
> via FluidAudio** (SenseVoice, Paraformer, Parakeet-ja, Nemotron) — see §2.2. The sherpa-onnx
> column is the fallback, not the only option.

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
- **Asian (zh/ja):** **Core ML/ANE in-process via FluidAudio** — **Parakeet-ja** (Japanese,
  fast) + **SenseVoice-Small** or **Paraformer-large** (Mandarin, fast). All ANE, tiny
  footprint, both channels (§2.2). Licence caveat: these are non-MIT (FunASR `license: other`
  / NVIDIA) — review before a paid release.
- **Hindi (its own model — per-language is fine):** **Whisper via WhisperKit**. Vanilla
  `large-v3` works now (MIT, pre-converted; Hindi ~17–19 WER). For better Hindi, **convert a
  Hindi-finetuned Whisper** (e.g. `vasista22/whisper-hindi-large-v2`,
  `ARTPARK-IISc/whisper-large-v3-vaani-hindi`) to Core ML with `whisperkittools` and run it via
  WhisperKit — same turnkey runner, dedicated model (check each finetune's licence). No Hindi
  *Core ML* model is pre-converted today; `Omnilingual-ASR-CTC-300M-CoreML` (Meta, 1600+ langs,
  fast CTC) is an alternative but needs a small DIY CTC-decode harness.

**Quality / "run overnight" tier (zh + ja + hi):**
- **Primary: Whisper `large-v3` (`v20240930`) via WhisperKit** — MIT, mature, best Hindi of
  the Whisper line. On 8 GB use the **quantized/compressed** variant (~0.55–1.08 GB); never
  ship f16 large-v3 on an 8 GB Mac (~10 GB working set → swap/crash).
- **Challenger: Qwen3-ASR-1.7B** (Apache-2.0, native `mlx-swift`, hosted in the server). If
  it wins on your audio, it collapses both tiers to one engine across zh/ja/hi.

**One thing worth a quick spike before committing:** the **`mlx-swift` Qwen3-ASR port**
(`ivan-digital/qwen3-asr-swift`) appears to be from the **same author as the seed article** —
active, ~macOS 15+, but its **sandbox/notarization behaviour is undocumented** and the
llama.cpp GGUF audio path has open long-audio bugs. Verify before relying on it. (In the
server architecture, the port runs in an unsandboxed Developer-ID process, which sidesteps
most of that risk.)

---

## 5. Sandbox + notarization — entitlements per backend

The app is sandboxed + Developer-ID-notarized today and may target MAS. Findings:

- **Core ML / ANE (WhisperKit, FluidAudio):** **no special entitlement.** This is the
  baseline.
- **MLX (mlx-swift / Qwen3-ASR):** **no `allow-jit`** in default builds (§3). Metal GPU
  access is normal. Weights cache to the sandbox container. *Verify* the specific Swift
  port under sandbox — it's young and undocumented on this point. (Moot if it runs in the
  Developer-ID server, which can be unsandboxed.)
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

**The big sandbox landmine:** the App Sandbox **prohibits spawning arbitrary subprocesses**,
so the common "ship `whisper-cli` as a sidecar and `exec` it" pattern is a **hard blocker for
an in-app backend**. Either link the backend **in-process** (§6 option a) **or** move it to a
**separate, independently-launched server** the app merely *connects* to (§6.1) — the server
isn't a subprocess of the sandboxed app, so the ban doesn't apply.

---

## 6. Distribution architecture — Developer ID vs Mac App Store

The core rule, verified against the App Review Guidelines (live-fetched 2026-06):

> **Model weights = data → downloadable on both channels. Executable backend code = only
> bundled-at-review for MAS; freely downloadable for Developer ID. A *separately-installed*
> app is neither — it sidesteps the rule entirely (§6.1).**

- **MAS forbids downloading executable code** that adds/changes features (2.5.2; only a
  narrow educational exception) and bars downloading "standalone apps, kexts, additional
  code or resources" that significantly change the app (2.4.5(iv)). Enforced actively
  (Replit/Vibecode/"Anything" pulled 2026-03).
- **MAS requires the sandbox** (2.4.5(i)); **Developer ID does not** — the direct-download
  channel is materially freer.

Options, scored for our case:

| Option | What it is | MAS | Developer ID | Verdict |
|---|---|---|---|---|
| **(a) In-process library** | Backend linked into the app binary | ✅ | ✅ | **Recommended for the light Core ML tiers** (~1–4 MB). WhisperKit/FluidAudio/whisper.cpp-from-source fit. MLX would add ~140 MB. |
| **(b) Bundled XPC service / helper tool** | Helper embedded **at build time** | ✅ (non-privileged only) | ✅ | Process isolation without a separate install. Helper signed with **exactly two** entitlements: `app-sandbox` + `inherit` (any extra, e.g. Xcode-injected `get-task-allow`, crashes it). Still inside the sandbox, so no `whisper-cli` subprocess and no post-install code download. |
| **(c) Separate bundled helper `.app`** | A second `.app` (LSUIElement) inside yours | ✅ (bundled at review) | ✅ | Allowed, but **cannot be *downloaded* post-install on MAS**. Mostly superseded by (f). |
| **(d) Downloaded code plugin / `.bundle`** | User downloads a loadable bundle after install (the SPM-spec satellite idea) | ❌ **forbidden** | ✅ | **Developer-ID-only**, and largely **obviated by (f)** — a server is the cleaner way to get heavy code onto the machine. |
| **(e) On-demand model download** | Fetch **weights** to Application Support / via Background Assets | ✅ (data) | ✅ | **Recommended for the weights**, both channels. |
| **(f) Standalone "Amanuensis Server"** | A separate, user-installed local HTTP/WS daemon the app *connects* to | ✅ (app just makes network calls) | ✅ (server is Dev-ID, unsandboxed, unconstrained) | **One option for the heavy/MLX tiers & multi-client** — keeps ~140 MB + sandbox-hostile work out of the app, at the cost of a second installable product. See §6.1. |

### 6.1 The "Amanuensis Server" — a standalone local transcription daemon (option f)

A separate product: a small app/daemon the user installs and runs **independently**, exposing
**HTTP** (batch) and/or **WebSocket** (streaming) on `127.0.0.1`. Amanuensis connects to it
as a client — and so can a CLI, Raycast, scripts, or other apps. This is *not* a bundled
helper (b/c) or a downloaded plugin (d); it's an **independent install**, which is exactly why
it sidesteps the MAS code rules.

**Caveat after the §2.2 finding:** the server is **no longer needed to avoid MLX bloat** —
Core ML/ANE in-process (WhisperKit + FluidAudio) already covers every requested tier (incl.
zh/ja/hi) at ~1–4 MB. So weigh the server purely on its *other* merits below (multi-client,
decoupling, independent updates), not as an MLX workaround.

**Why it's attractive for the heavy/MLX tiers:**
- The MAS bans (2.5.2 / 2.4.5) are on *the app* fetching/executing new code. A
  separately-installed server is **not the app fetching code** → all the heavy,
  sandbox-hostile work (**MLX's ~140 MB**, whisper.cpp, model downloads to anywhere, even
  spawning subprocesses) lives in the **server**, shipped via **Developer ID, unsandboxed,
  unconstrained**.
- The sandbox subprocess ban becomes irrelevant — the app opens a socket, it doesn't spawn.
- The MAS **app stays tiny** (network code only; you can skip even Core ML if everything
  routes through the server).

**It reuses both existing seams — near-zero new app code:**
- **Batch:** the server speaks OpenAI-compatible `POST /v1/audio/transcriptions`. Amanuensis
  **already** has the `transcriptionMultipart` shape pointed at a configurable
  `Provider.baseURL`. So "local transcription" is just **a provider with
  `baseURL = http://127.0.0.1:PORT`** — *no new handler*, and the keyless-carve-out friction
  (§8.1) disappears (store a dummy local token, or the server ignores auth). The HTTP-centric
  `Provider`/`Preset` model that was *friction* for an embedded backend is a *perfect fit*
  here.
- **Streaming:** the server's WS endpoint → a `DictationTranscriber` conformer via
  `URLSessionWebSocketTask` to `ws://127.0.0.1:PORT`, identical to the cloud streaming
  providers in `realtime-streaming-asr-research.md` (same commit-window UX).

**Entitlements:** the app needs only `com.apple.security.network.client` — **already present**
(it's what the cloud connectors use; it covers loopback). The server, *if* sandboxed, needs
`com.apple.security.network.server`; as a Developer-ID **unsandboxed** process it needs none
(recommended, for full ML freedom).

**Costs / things to get right:**
- **Lifecycle.** The sandboxed app **can't launch** the server (subprocess ban) and, on MAS,
  can't install it. So the server **self-installs as a `launchd` LaunchAgent** (or a menu-bar
  app) and stays resident; the app **health-checks the port** and **degrades gracefully**
  (fall back to cloud, or show "Start Amanuensis Server"). This is the main UX cost.
- **MAS self-containment risk.** App Review expects the app to function on its own. Keep cloud
  connectors working **without** the server and present local transcription as an *optional
  accelerator*; **never bundle or auto-install** the server from the MAS build. (Judgment
  call — verify with Review; talking to a localhost endpoint is ordinary network traffic, but
  *requiring* a separate install to function is the line to stay behind.)
- **Loopback security.** Bind `127.0.0.1` only and require a **shared token** (app generates
  it, hands it to the server via a first-run handshake/config, sends it as a bearer header) so
  other local processes can't quietly use — or abuse — your transcription service.
- **More to build/maintain** — you're shipping a small private, offline "Groq." But it's
  decoupled, **independently updatable without App Review**, and reusable. You may not even
  write it from scratch: **whisper.cpp ships `whisper-server`** with an OpenAI-compatible HTTP
  API, and llama.cpp's server speaks OpenAI too.
- **Server internals:** a thin Swift HTTP/WS server (Hummingbird / Vapor / NIO, or
  `Network.framework`) wrapping WhisperKit / FluidAudio / MLX-Qwen3 / whisper.cpp **in-process
  within the server**. Since the server is unconstrained, mix freely and update independently.

### 6.2 What's "data" vs "code" — and model-weight download mechanics

**Does a `.metallib` count as executable code?** Model *weights* are unambiguously **data**.
A `.metallib` (including `mlx.metallib`) is **compiled GPU shader programs** — much closer to
code — so a *downloaded* metallib most likely falls under the MAS "executable code" bar
(2.5.2 / 2.4.5(iv)). Practical consequence: **on MAS you cannot shrink the app by downloading
the MLX runtime/metallib after install** — it must ship in the bundle (or be built with
`MLX_METAL_JIT`, which runtime-compiles kernels from *embedded* MSL source on-device — that's
compilation, not a download, so it's fine on MAS, just slower on first run). On **Developer
ID** none of this applies — download whatever you like. *No explicit Apple ruling on metallib
classification was found; treat this as a conservative inference and verify before betting a
MAS submission on downloading a metallib.*

- **Background Assets** is the idiomatic framework (macOS 13+, covers our 26.x target) with
  essential / prefetch / on-demand policies. macOS 26 adds **Apple-Hosted** packs (200 GB
  free in the Developer Program, accelerated ML-model update path **without** resubmitting
  the app) — **but Apple-hosting is App Store / TestFlight only.**
- For **Developer ID** (and the server), do **not** assume Background Assets self-hosting
  works — the "Apple-hosted *and* self-hosted dual path" claim was **refuted (1-2)**. Safest:
  a plain **`URLSession` download into Application Support** (which is also what
  WhisperKit/FluidAudio already do from Hugging Face).

### 6.3 Choosing among the options (no forced default)

It depends on how much you want to ship and maintain:
- **Light Core ML tiers** are easy either way — **(a) + (e)** in-process is ~1–4 MB and
  "just works" on MAS. Little reason to do anything fancier for these.
- **Heavy / MLX tiers** are where the choice bites — pick per priorities:
  - **Bundle MLX** — simplest to ship, one product, works on both channels; but ~140 MB
    (smaller via `MLX_METAL_JIT`), and on MAS the metallib can't be slimmed by a later
    download (§6.2).
  - **Developer-ID-only downloaded plugin (d)** — keeps the app small, but no MAS.
  - **Amanuensis Server (f)** — most decoupling, both channels, multi-client reach; but a
    separate product to build, install, and keep running.
- **(d)** and **(f)** both keep heavy code off the app; **(d)** is Dev-ID-only, **(f)** works
  on both. Trade app-size / MAS-simplicity against avoiding a second installable product —
  this is an open call.

---

## 7. Streaming vs batch on-device

- **Batch** (the Jobs path) is latency-tolerant and trivially served by any backend here —
  in-process or via the server's HTTP endpoint.
- **Streaming** (live dictation) splits into two kinds:
  - **Chunked / VAD pseudo-streaming** over an encoder-decoder model (WhisperKit's
    `AudioStreamTranscriber`, ~0.45 s/word reported; whisper.cpp stream example). Latency is
    bounded by the chunk/window — fine, not great.
  - **True streaming** transducer/Zipformer models (Parakeet via FluidAudio's
    `SlidingWindowAsrManager`; sherpa Zipformer). Lower latency, partial results designed in
    — FluidAudio cites a Parakeet EOU variant at ~0.13 s **full-pipeline** in a third-party
    app (not an isolated ASR RTF; treat as directional).
- **For our realtime path, FluidAudio/Parakeet is the strongest on-device streaming engine**
  — but English/European only, so a multilingual live-dictation story needs Whisper
  chunked-streaming (or a Qwen3 server endpoint). Either way it surfaces the same way: a
  `DictationTranscriber` conformer over an in-process engine **or** over a `ws://127.0.0.1`
  server endpoint. This mirrors the realtime-cloud doc's conclusion: streaming is its own seam
  with its own UX problem (the "commit window" for revising partials), not a reskin of batch.

---

## 8. How it fits Amanuensis (integration plan)

The codebase already has both seams. Batch and streaming attach in different places — keep
them separate.

### 8.1 Batch — a new `AudioJobSending` handler (in-process variant)

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

### 8.2 Batch — the server variant (reuse, don't extend)

If the backend lives in the **Amanuensis Server (§6.1)**, the batch path needs **no new
handler at all**: the server exposes OpenAI-compatible `POST /v1/audio/transcriptions`, and
the existing `transcriptionMultipart` shape already targets a configurable
`Provider.baseURL`. So you add a **provider row with `baseURL = http://127.0.0.1:PORT`** and a
dummy/local token, and the existing pipeline runs unchanged. **This also avoids the §8.1
keyless carve-outs** (the provider has a token, even if the server ignores it). Net: the
server variant is *less* app-side code than the in-process variant — at the cost of building
and shipping the server.

### 8.3 Streaming — a new `DictationTranscriber` conformer

```swift
// Packages/AudioPipeline/Sources/DictationCore/DictationTranscriber.swift:6
// doc comment: "A future websocket/MLX engine emits interim text via onPartial."
```

A local streaming engine is a new conformer (`LocalTranscriber: DictationTranscriber`)
parallel to `BatchTranscriber` (`BatchTranscriber.swift:7`), emitting `onPartial`/`onFinal`.
It can wrap an **in-process** engine or a **`ws://127.0.0.1` server endpoint** (the latter is
mechanically identical to the cloud `URLSessionWebSocketTask` conformers in the realtime doc).
The dictation spec (`docs/superpowers/specs/2026-06-18-dictation-design.md:349`) already names
the seam (`MLXTranscriber: DictationTranscriber`). **Do not** route streaming through
`AudioJobSending`.

### 8.4 Off-main inference (the concurrency rule)

The package uses default `MainActor` isolation with `NonisolatedNonsendingByDefault`, so a
bare `nonisolated async func` **inherits the caller's actor** — it does *not* move off-main
by itself. Inference must be **explicitly** dispatched. Mirror the existing precedents:
- `RecordingConversionService` — a `public actor` running heavy work on
  `Task.detached(priority: .utility)` (`RecordingConversionService.swift:47`).
- `AudioCompressor.compressToM4A`, wrapped in `Task.detached(.utility)` by its caller
  precisely for this reason (`TranscriptionMultipartHandler.swift:89`).

Put any **in-process** model + inference loop behind a dedicated `actor` (or `Task.detached`),
never a bare `nonisolated async`. (The server variant moves this concern into the server
process entirely — the app just does async network I/O, which it already handles.)

### 8.5 Heavy-dependency isolation

The SPM module spec (`docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md`
§333-335) already plans a **separately-codesigned satellite `.bundle`** outside the umbrella
package so `AudioPipeline*` never takes an MLX/Core ML dependency. That intent holds, refined
by §6: a *downloaded* satellite bundle is **Developer-ID-only**, whereas the **Amanuensis
Server** achieves the same isolation **for both channels** (the heavy dependency is in a
separate process/product, not loaded into the app at all). For a MAS build that wants MLX
without the server, the alternative is compiling MLX in (~140 MB; §2.1) — usually not worth
it versus routing through the server.

### 8.6 Settings / model management UI

A new Section in `SettingsView.swift:61` (next to Dictation) is the natural home for model
download/management and a server status/health row. An in-process local backend has no API
key, so it sidesteps the Keychain/provider flow; the server variant reuses the normal provider
UI (with a localhost `baseURL`). Per-job model selection already works via the preset's
`suggestedModels`.

---

## 9. Recommendation matrix

| Tier | Where it runs | Backend / model | Licence | Channel fit | Notes |
|---|---|---|---|---|---|
| **Fast — English** | in-process | FluidAudio Parakeet-0.6B-v2 (Core ML/ANE) | code MIT; NVIDIA weights (verify) | both | ~66 MB working set, ~3.5 MB code, true streaming. Fallback Whisper `small.en` (MIT). |
| **Fast — European** | in-process | Parakeet-0.6B-v3 / Whisper `small` | MIT(-ish) | both | Parakeet=speed, Whisper=licence simplicity. |
| **Fast — Asian zh/ja** | in-process | FluidAudio: Parakeet-ja + SenseVoice/Paraformer (Core ML/ANE) | non-MIT (verify) | both | Turnkey, fast, tiny; §2.2. |
| **Hindi** | in-process | Whisper via WhisperKit | **MIT** | both | `small`→`medium`; clean cross-lingual incl-Hindi path. |
| **Quality — all langs** | in-process **or** server | Whisper **large-v3** (quantized, WhisperKit) | **MIT** | both | Overnight tier; never f16 on 8 GB. |
| **Hindi (better WER, optional)** | in-process | Hindi-finetuned Whisper via WhisperKit (convert w/ whisperkittools) | per-finetune (verify) | both | Dedicated Hindi model, same Core ML runner; §4.3. |
| **zh/ja specialist (optional)** | in-process or server | SenseVoice-Small (sherpa-onnx) | bespoke Alibaba | both (Embed & Sign) | Best/fastest zh; no Hindi; keep licence text on file. |

**Phasing suggestion:**
1. **Prove the batch seam end-to-end with WhisperKit in-process** (lowest friction, both
   channels, ~1.2 MB).
2. Add **FluidAudio/Parakeet** for the fast English/European tier + the streaming
   `DictationTranscriber` conformer.
3. **Decide where the heavy/MLX tiers live** (§6.3: bundle / Dev-ID plugin / server). If you
   go the server route, stand it up here (start from `whisper-server` or a thin Hummingbird
   wrapper) and wire Amanuensis to it as a `http://127.0.0.1` provider.
4. Add **Qwen3-ASR (MLX)** for the Asian tier — in whichever home step 3 picked.
5. Add **Whisper large-v3** as the overnight quality tier (in-process or server).
6. Optional: **SenseVoice** if Chinese accuracy becomes a headline feature.

---

## 10. Open questions / spikes before committing

1. **Best Hindi model (its own tier).** No dedicated Hindi *Core ML* model is pre-converted.
   Compare: vanilla Whisper `large-v3` (turnkey, ~17–19 WER) vs converting a Hindi-finetuned
   Whisper (`vasista22/whisper-hindi-large-v2`, `ARTPARK-IISc/whisper-large-v3-vaani-hindi`) via
   `whisperkittools` (better WER, check licence) vs `Omnilingual-ASR-CTC-300M-CoreML` (fast CTC,
   needs a DIY decode harness). Qwen3-ASR (one-model zh+ja+hi) is no longer needed now that
   per-language is acceptable.
2. **NVIDIA Parakeet *weight* licence** — confirm commercial-use terms (code is MIT/Apache;
   the model weights are the question) before shipping FluidAudio in a paid app.
3. **Cold-start / first-run Core ML compile latency and steady-state memory on a true 8 GB
   machine** — the 190×/M4-Pro figures don't represent the low-end target. Measure WhisperKit
   large-v3-turbo (0.6 GB) vs FluidAudio Parakeet on the actual floor hardware.
4. **Server lifecycle** — `launchd` LaunchAgent install/auto-start UX, health-check protocol,
   graceful "server not running → fall back to cloud" behaviour, and the loopback shared-token
   handshake.
5. **MAS self-containment review** — confirm with App Review that an *optional* localhost
   server (app fully functional without it) is acceptable, and that the app never installs it.
6. **Server build vs reuse** — evaluate whether `whisper-server` (OpenAI-compatible HTTP) is
   enough to start, or whether a thin Swift HTTP/WS wrapper around WhisperKit/MLX is worth
   owning for the WS/streaming endpoint and multi-engine routing.
7. **whisper.cpp `default.metallib` packaging** — only if we adopt whisper.cpp; verify the
   precompiled-metallib build is sandbox-clean and survives a macOS point release.
8. **SenseVoice/FunASR licence** — non-OSI, HF tags self-contradict; keep the exact
   `MODEL_LICENSE` text on file if used. Avoid WenetSpeech-trained Chinese Zipformers in a
   paid app (non-commercial training data).

---

## Sources

**Backends, Swift integration & bundle sizes**
- WhisperKit — <https://github.com/argmaxinc/WhisperKit> · Core ML weights
  <https://huggingface.co/argmaxinc/whisperkit-coreml> · OD-MBP paper (arXiv 2507.10860)
  <https://arxiv.org/pdf/2507.10860>
- FluidAudio — <https://github.com/FluidInference/FluidAudio> · Parakeet Core ML
  <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml> · ANE footprint
  <https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/>
- MLX size (`mlx.metallib` 119.6 MB, `libmlx` 20.6 MB) — `mlx-metal` wheel
  <https://pypi.org/project/mlx-metal/#files> · build/JIT flag
  <https://ml-explore.github.io/mlx/build/html/install.html> · mlx-swift bundling pain
  <https://github.com/ml-explore/mlx-swift/issues/345>
- whisper.cpp — <https://github.com/ggml-org/whisper.cpp> (v1.9.1 xcframework inspected) ·
  `whisper-server` (OpenAI-compatible HTTP) in `examples/server` · SwiftWhisper
  <https://swiftpackageindex.com/exPHAT/SwiftWhisper> · whisper.spm
  <https://github.com/ggerganov/whisper.spm> · GGML Metal loader
  <https://github.com/ggml-org/llama.cpp/blob/master/ggml/src/ggml-metal/ggml-metal-device.m>
- ONNX Runtime (~28 MB dylib) — <https://pypi.org/project/onnxruntime/#files> · CoreML EP
  <https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html> · sherpa-onnx
  community SPM <https://swiftpackageindex.com/willwade/sherpa-onnx-spm>

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
