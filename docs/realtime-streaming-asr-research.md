# Realtime streaming ASR — research, design & feasibility

> **Status:** research + design, now partly implemented. Compiled 2026-06-29; status updated 2026-07-04.
> **Wired since:** four streaming adapters live in `Packages/AudioPipeline/Sources/AudioPipelineJobs/` — **Reson8**, **Soniox**, **Deepgram**, and **OpenAI** (realtime transcription; defaults to `gpt-4o-transcribe` + server VAD, and is the base64-PCM-in-JSON protocol outlier) — each a `RealtimeSTTProvider` (client + result decoder + URL builder), selected by preset id through `RealtimeProviderRegistry` (which also gates the Settings "Stream results live" toggle). AssemblyAI and the other providers below remain candidates, not yet built.
> **Goal:** add a *live* dictation mode to Amanuensis where words appear on screen / in
> the target app as you speak, with minimal perceived delay — versus today's
> record-then-transcribe batch path.
> **Decision frame (from the brief):** support several of the best/most common cloud
> streaming providers behind one abstraction (shortlist = Reson8, Soniox, ElevenLabs,
> Cartesia, balanced picks). Cloud only — on-device (Apple SpeechAnalyzer / WhisperKit /
> Parakeet) is explicitly out of scope here. Languages: take what each provider offers.

---

## 1. TL;DR

1. **Feasible with what you already have.** Every candidate is a single client-driven
   **WebSocket** that takes mono 16-bit PCM and streams back JSON partials/finals.
   `URLSessionWebSocketTask` (Foundation, built-in) handles this — **no Starscream /
   SwiftNIO needed**, and **no new entitlement** (your `com.apple.security.network.client`
   already covers it). The audio you'd send is *exactly* the 16 kHz mono Int16 that
   `DictationWAVWriter` already produces today.

2. **Your architecture already has the seam.** `DictationTranscriber`
   (`Packages/AudioPipeline/Sources/DictationCore/DictationTranscriber.swift`) was written
   with `onPartial`/`onFinal` callbacks and a doc comment that literally says *"A future
   websocket/MLX engine emits interim text via `onPartial`."* A streaming engine is a new
   conformer of that protocol, not a rearchitecture. The existing `AudioJobSending`
   (file-in / text-out) protocol cannot express streaming and should be left alone for
   batch jobs.

3. **The hard part is not the network — it's the UX of live insertion ("continuous
   pasting").** Streaming STT emits a *revising* tail ("I want to" → "I wanted to"). The
   industry-standard fix is a **commit window**: buffer the unstable tail, only insert
   words once they've stabilized (N stable updates / debounce / marked final). This
   sidesteps almost all of the "edit already-typed text" problem. See §5.

4. **The "ephemeral token" noise in vendor docs mostly doesn't apply to you.** Those exist
   so a *public web/mobile app* can connect untrusted clients without shipping the
   developer's key. Amanuensis is a desktop app where **the user's own API key lives in
   their own Keychain** — you can connect the WebSocket directly with that key (header or
   query param) and skip building any token-minting backend. This is a real simplification.
   (Exception: ElevenLabs' realtime endpoint may *require* a single-use token even
   server-side — verify per provider; see §3 notes.)

5. **No clear single winner, which is fine — the brief wants multiple.** They cluster into
   two behavioural families that change your insertion code (§5):
   - **Revisable-partials** (ElevenLabs, Soniox, Deepgram, Speechmatics, Gladia, OpenAI,
     Cartesia-manual) — fastest words on screen, needs the commit window.
   - **Immutable / append-only** (AssemblyAI, Cartesia-auto) — simpler insertion (no
     rewrites), but words appear only when a chunk finalizes (~300 ms+).
   For a first cut: **Deepgram Nova-3** or **Soniox** (cheap, revisable partials, fine
   endpointing control, strong multilingual) as the streaming default, with **AssemblyAI**
   as the "immutable, simplest-to-insert" alternative. All three are cheap and GA.

---

## 2. Provider comparison

All nine are **WebSocket, mono PCM in, JSON out, GA** (except where noted), with **no
official Swift SDK** (you drive `URLSessionWebSocketTask` directly in every case). Latency
figures are **vendor/benchmark claims, not SLAs**, and "ms" numbers below mix
time-to-first-partial and time-to-final — read them as rough tiers, not exact.

| Provider / model | Partial style | Latency (claimed) | Streaming price | Streaming languages | Endpointing control | Notes |
|---|---|---|---|---|---|---|
| ✅ **Soniox** `stt-rt-v5/v4` | Revisable tokens (`is_final` per token) | ~249 ms median to final; partials "ms" | ~**$0.12/hr** | **60+**, auto-detect + mid-stream code-switching | Semantic endpoint + manual `finalize`, tunable | Direct-stream + temp-key model built for clients. **Quotas: 10 concurrent, 300-min hard session cap.** Diarization, translation, smart formatting bundled. |
| ✅ **Deepgram** `nova-3` | Revisable interims (`is_final`/`speech_final`) | sub-300 ms TTFT | **$0.29/hr** mono, $0.35 multi | 10 via `language=multi` code-switch | `endpointing` ms + `UtteranceEnd` + `Finalize` | $200 free credit. 150 concurrent (PAYG). Community iOS sample (Starscream). Token survives mid-session expiry. |
| **AssemblyAI** Universal-Streaming v3 | **Immutable** (word-level `word_is_final`, Turn objects) | ~300 ms P50 | **$0.15/hr** (EN/multi); Pro ~$0.45 | EN-only or multilingual model (ES/FR/DE/IT/PT); Pro ~18 | Semantic+acoustic end-of-turn, `ForceEndpoint` | **Billed on connection-open time** — must send `Terminate`. v2 endpoint EOL ~Jan 2026, use v3. Immutable = no flicker, simplest insertion. |
| **ElevenLabs** Scribe v2 Realtime | Revisable (`partial_transcript` → `committed_transcript`) | ~150 ms (markets "negative latency") | ~**$0.28/hr** | **90+**, auto-detect, code-switch | Manual `commit` or tunable VAD | Single-use 15-min token (may be required). Word+char timestamps, keyterms. **No realtime diarization.** GA (launched late 2025). |
| **Cartesia** Ink (`ink-whisper`/`ink-2`) | Manual endpoint: revisable (`is_final`); **Auto endpoint: append-only** | ~66 ms median TTCT (ink-whisper) | ink-whisper ~**$0.13/hr**; ink-2 3× | ink-whisper multilingual (undocumented list); **ink-2 EN-only** | Manual `finalize`/`close`, or model auto-turn | STT-scoped 1-hr token. Fast/cheap but built for voice-agent turn-taking; no documented diarization. |
| **Speechmatics** RT (Ursa) | Revisable (`AddPartialTranscript`/`AddTranscript`) | partials <500 ms; finals floor **0.7 s** (`max_delay`) | "from $0.129/hr" (unconfirmed) / older $1.04–1.35 | 55–80+, **no realtime auto-detect** (must set language) | `max_delay` 0.7–4 s + silence `EndOfUtterance` + `ForceEndOfUtterance` | Mature. **Self-hosting / on-prem (Docker/K8s/appliance)** — unique here. Diarization, custom vocab, translation. EU endpoint. |
| **Gladia** Live v2 (Solaria-1) | Opt-in partials (`is_final`) | ~270 ms first response, ~100 ms partials claimed | **$0.75/hr**, 10 free hrs/mo | **100**, auto-detect + code-switching | `endpointing` 0.05–10 s (50 ms default) + `stop_recording` | **Init POST → returns token-bearing `wss://` URL** (slightly different flow). 30 concurrent (Starter). On-prem is enterprise roadmap. |
| ✅ **OpenAI** Realtime (`gpt-realtime-whisper`) | Revisable deltas (`…transcription.delta`/`.completed`) | "low latency", `delay` knob; no number | ~$0.003–0.006/min (~$0.18–0.36/hr) | Whisper-lineage ~90+ (not enumerated for RT) | Server VAD, or manual `input_audio_buffer.commit` | WS **or WebRTC**; ephemeral client secrets. Audio is **base64 PCM inside JSON** (not raw binary frames) — a protocol outlier. Use `gpt-realtime-whisper`, not `gpt-4o-transcribe` (batch-leaning). |
| ✅ **Reson8** RT | Opt-in interim (`include_interim`, `is_final`) | **not published** | 2 credits/min (~€20/6000cr) | **9** (EU langs), no documented auto-detect | **Manual flush only** (no silence VAD) | March-2026 startup, thin docs, no SDK, no published latency. **EU-only processing + zero retention** is the differentiator. Diarization (≤4), domain adaptation. |

> ✅ = streaming adapter already implemented in the app (`RealtimeSTTProvider` + `RealtimeProviderRegistry`). Everything else is a candidate.

### How to read this for your goal

- **"Words appear as I speak" favours revisable-partials providers.** AssemblyAI/Cartesia-auto
  feel slightly more "chunked" because they only show finalized text — but they're *easier*
  to wire into live insertion because emitted text never gets rewritten.
- **Cheapest GA, multilingual, revisable:** Soniox (~$0.12) and Deepgram ($0.29). AssemblyAI
  is cheapest overall ($0.15) but immutable + English-leaning.
- **Privacy / data-residency hard requirement:** Speechmatics (on-prem today) or Reson8
  (EU-only, zero retention). Gladia is EU-hosted + SOC2/HIPAA but on-prem is roadmap.
- **Watch-outs:** Soniox 300-min session cap + 10 concurrent; AssemblyAI bills on
  connection-open time (always `Terminate`); Speechmatics has **no realtime auto language
  detection**; Cartesia `ink-2` and AssemblyAI English model are English-only; Reson8 is
  immature.

---

## 3. The common protocol shape (what the abstraction must cover)

Despite per-vendor naming, the realtime contract is nearly identical everywhere. This is
what makes a single Swift abstraction viable:

1. **Open** a WebSocket to `wss://…` (Gladia: first do an `init` POST that *returns* the ws
   URL; OpenAI: optionally WebRTC instead).
2. **Configure** the session — either as **query-string params** on the URL
   (Deepgram, AssemblyAI, ElevenLabs, Reson8, Cartesia), a **JSON config first message**
   (Soniox, Speechmatics `StartRecognition`, OpenAI `session.update`), or the **init POST
   body** (Gladia). Config = model, encoding, sample_rate, channels, partials on/off,
   endpointing thresholds, language(s), features (diarization, formatting, keyterms).
3. **Auth** — header (`Authorization: Token/Bearer …`, `xi-api-key`, `x-gladia-key`,
   `X-API-Key`) or query param (`?token=`/`?jwt=`/`?access_token=`), or in the first JSON
   message (Soniox `api_key`). **For Amanuensis, use the user's own Keychain key directly**
   (see §4); ephemeral tokens are optional infra you don't need.
4. **Stream audio up** as **binary WebSocket frames** of PCM (OpenAI is the outlier:
   base64 PCM inside JSON `input_audio_buffer.append`). Pace at ≈ real-time; typical chunk
   ~50–120 ms of audio (a few KB) — small enough that the 1 MiB receive cap is irrelevant.
5. **Receive results** as JSON text frames carrying:
   - a transcript string + a `words[]`/`tokens[]` array with per-word `start`/`end`
     timestamps and `confidence`,
   - a **final/non-final flag** (`is_final` / `word_is_final` / `speech_final` /
     committed-vs-partial / Turn `end_of_turn`),
   - optional `speaker`, `language`, endpoint/turn events.
6. **Finalize / endpoint** — silence-based VAD (tunable thresholds) and/or a manual
   flush/finalize control message (`Finalize`, `finalize`, `commit`, `ForceEndpoint`,
   `ForceEndOfUtterance`, `flush_request`, `stop_recording`).
7. **Close** — a graceful close/terminate message so trailing audio is flushed (and, for
   AssemblyAI, so you stop being billed).

> **Design takeaway:** a `RealtimeSTTProvider` abstraction needs: a way to build the
> connect URL+headers, a way to encode the config, an audio-frame encoder (raw binary vs
> base64-JSON), and a result decoder that normalizes each vendor's message into a common
> `{ words, isFinal, speaker?, language? }` event. Seven of nine fit one shape; OpenAI
> (base64+events) and Gladia (init POST) are the two that need small per-adapter quirks.

---

## 4. Swift / macOS feasibility

**Verdict: green. `URLSessionWebSocketTask` is sufficient; no third-party WS library; no
new entitlement.**

- **Binary up / text down on one socket:** `URLSessionWebSocketTask.send(.data(…))` sends
  raw PCM frames; `receive` (re-armed in a loop) delivers JSON `.string` messages. Both on
  one task. (For OpenAI you'd `send(.string(json))` with base64 audio instead.)
- **Sandbox:** WebSocket is an HTTP/1.1 Upgrade over normal outbound TLS — covered by the
  **existing** `com.apple.security.network.client` entitlement
  (`Amanuensis/Amanuensis.entitlements`). No code currently uses `URLSessionWebSocketTask`
  anywhere in the repo, so this is greenfield but standard.
- **Keepalive / liveness:** `sendPing(pongReceiveHandler:)` is built in; several providers
  also accept JSON `KeepAlive`. Reconnect/backoff is your responsibility (true of any lib).
- **`maximumMessageSize`** defaults to 1 MiB (received). Non-issue: PCM frames are a few KB
  and result JSON is tiny.
- **No API key on the wire to untrusted parties:** the key is the *user's own*, read from
  `KeychainStore` (`work.miklos.amanuensis.api-keys`) exactly like the batch handlers do
  today, and sent straight to the provider over TLS. **You do not need a token-minting
  backend.** (One caveat: confirm whether ElevenLabs' realtime endpoint *requires* a
  single-use token even when you hold the key — if so, that one provider needs an extra
  REST call before connecting.)
- **Concurrency fit:** the audio tap closures are already `nonisolated`/`@Sendable`
  (`DictationRecorder`, `MicRecorder`, `ProcessTapRecorder.handle`). A WebSocket send from
  the audio callback is fine if the socket client is an `@unchecked Sendable` class
  serializing on its own queue — mirror `AudioFileWriter`/`DictationWAVWriter` (which
  already hop buffers to a private `DispatchQueue`). **Watch the existing `ResultRef`
  caveat** in `DictationCoordinator.swift:233-237`: today it's safe only because
  `BatchTranscriber` calls `onFinal` exactly once, synchronously. A streaming engine fires
  `onPartial`/`onFinal` repeatedly and **off the main thread**, so that hand-off needs real
  synchronization (hop to `MainActor`).

---

## 5. "Continuous pasting" — live text insertion (the real design problem)

Streaming STT revises its tail as more audio arrives. If you naively insert every partial,
the target app visibly flickers and rewrites. Two questions: **(A) what mechanism inserts
text into the frontmost app, and (B) when do you insert?**

### A. Insertion mechanism — today vs. what live needs

Today, `TextInserter` (`Amanuensis/Dictation/TextInserter.swift`) does **one-shot clipboard
+ synthesized ⌘V** (snapshot pasteboard → write text → `CGEvent` ⌘V → restore), gated on
**Post Event access** (`CGRequestPostEventAccess`), *not* the Accessibility API. That's
perfect for committing a finalized block, but a clipboard paste is a blob — it can't
"update" already-inserted text.

The three real macOS mechanisms, and how they handle *revision*:

| Mechanism | API | Revision support | App coverage | Best for |
|---|---|---|---|---|
| **Clipboard + ⌘V** (current) | `NSPasteboard` + `CGEvent` | None (one-shot blob) | ~Everywhere | Committing finalized blocks |
| **Synthesized keystrokes** | `CGEvent` keycodes + `keyboardSetUnicodeString` | **Backspace-diff**: delete changed suffix, retype | Anywhere typing works | Universal fallback, incremental + revision |
| **Accessibility direct set** | `AXUIElement` + `kAXSelectedTextAttribute` / `kAXSelectedTextRange` | **Replace-in-place**, no flicker | Native Cocoa good; Electron/web/terminal patchy/read-only | Best UX where supported |

Real products (Wispr Flow, SuperWhisper-class) use a **layered fallback**: try **AX direct
insert → fall back to keystrokes → fall back to clipboard paste**, detecting failure by
checking whether the field value actually changed. AX adds an **Accessibility** TCC grant
on top of the Post-Event access you already request.

### B. When to insert — the commit-window / stability pattern

This is the trick that makes it feel good and **largely removes the need to edit
already-inserted text**:

- Treat **partials as draft, finals as commit.** Hold back the unstable tail; only insert a
  word once it has **stabilized** — unchanged for K consecutive partials, or past a
  debounce (~200–400 ms), or marked final by the service (`is_final`/`word_is_final`/
  end-of-turn). (AWS calls this "partial-results stabilization": only the last few words of
  a partial can change, so everything before is safe to emit.)
- Keep a **committed prefix**: insert only the newly-stable delta; keep the volatile suffix
  in an internal buffer. Optionally show that volatile suffix in **your own overlay**
  (`DictationOverlayController` already exists) rather than in the target app — then the
  target app only ever receives committed text and **never flickers**. This overlay-then-
  commit pattern (cf. Wispr Flow's "Flow Bar") is the safest, most common UX.
- On a **VAD/endpoint signal** (silence) flush the segment as final. Pair the model's
  end-of-utterance with your own VAD backstop (`forceEndOfUtterance`) since stray noise
  tokens can stall the model's debounce.

**Consequence for mechanism choice:** if you commit only stabilized text, the common case
is *append-only* and the current **clipboard-⌘V path still works** (paste each committed
chunk). You only need the keystroke-backspace or AX-replace path for the *rare* case where
an already-committed word later changes — which a good commit window keeps to a minimum.
**Immutable providers (AssemblyAI / Cartesia-auto) never revise committed text at all**, so
with them append-only insertion is always correct.

> **Recommended live-insertion design for Amanuensis:** show the volatile tail in the
> existing overlay; commit stabilized words to the target app. Start by reusing
> `TextInserter`'s clipboard-⌘V to paste each committed chunk (append-only — minimal change,
> no new permission). Add an AX-first → keystroke → clipboard fallback chain later if you
> want true in-place revision and less clipboard churn. Mark transient clipboard writes with
> `org.nspasteboard.TransientType` so clipboard managers ignore them.

---

## 6. How it fits the Amanuensis architecture

Concrete extension points found in the codebase map:

1. **Transcriber seam (primary):** add a `StreamingDictationTranscriber: DictationTranscriber`
   that opens the WebSocket, streams audio, and calls `onPartial` (volatile tail) /
   `onFinal` (committed text). `BatchTranscriber` stays as-is for the batch path. The
   protocol's doc comment already anticipates exactly this.
2. **Audio source:** fan the buffers that `DictationWAVWriter`/`DictationRecorder` already
   produce (16 kHz mono Int16, on a background queue, `DictationRecorder.swift:24`) to a WS
   `send` instead of — or in addition to — the file write at `DictationWAVWriter.swift:83`.
   The existing `onLevel` callback is the model for an `onAudioChunk` callback. **No new
   capture code or format conversion needed** — vendors want precisely this format.
3. **Coordinator flow:** `DictationCoordinator.endCaptureAndTranscribe` (line 194) assumes
   record-*then*-transcribe; streaming is send-*while*-recording. The `DictationStateMachine`
   gains a streaming/partial phase, and the no-op `onPartial: { _ in }` (line 210) becomes
   the live-insert path. Fix the `ResultRef` synchronization (lines 233-237) for off-thread
   `onFinal`.
4. **Provider model:** the **batch** `JobShape`/`AudioJobSending` (file-in/text-out) cannot
   express streaming and should **not** be forced to. Add a parallel, small
   `RealtimeSTTProvider` protocol (connect URL/headers builder + config encoder + frame
   encoder + result decoder; see §3) with one adapter per provider. Reuse the existing
   `Provider`/`Preset`/`presets.json` + `KeychainStore` machinery for base URL, model, and
   key — add streaming presets (you already ship `deepgram` and `soniox-async` presets; the
   realtime variants are new shapes/presets, not new providers).
5. **Settings:** extend `DictationSettings`
   (`Packages/AudioPipeline/Sources/DictationCore/DictationSettings.swift`) with e.g.
   `streamingEnabled` + a realtime `providerID`, surfaced in the existing
   `SettingsView.swift:61` Dictation section (reuse the provider picker + model field).
6. **Errors/observability:** reuse `LogStore` + `JobErrorRendering` so connection/auth/
   stream errors surface in the Logs view like batch jobs do today.

---

## 7. Feasibility verdict & suggested phasing

**Verdict: feasible and well-scoped.** The networking is standard, the audio format is
already right, the transcriber seam exists, and the only genuinely new design work is the
commit-window + live-insertion UX (§5) and a thin provider abstraction (§3).

Suggested phases (each independently shippable):

- **Phase 0 — spike:** one hard-coded provider (Deepgram or Soniox — cheap, revisable
  partials, simple query-string config, raw binary frames), `URLSessionWebSocketTask`,
  print partials to the log. Proves the socket + audio fan-out + the `ResultRef`/threading
  fix. No UI.
- **Phase 1 — overlay-only live view:** render the streaming tail in the existing
  `DictationOverlayController`; commit nothing to the target app yet. Validates the
  commit-window/stability logic visually with zero insertion risk.
- **Phase 2 — append-only commit:** insert committed (stabilized/final) chunks into the
  target app via the existing clipboard-⌘V `TextInserter`. End-to-end live dictation for the
  common case. (Pick an immutable provider like AssemblyAI here to make commit trivially
  correct, or apply the commit window to a revisable one.)
- **Phase 3 — provider abstraction:** extract `RealtimeSTTProvider`, add 2–3 adapters
  (e.g. Soniox + Deepgram + AssemblyAI), wire the settings picker. **Done:** Reson8,
  Soniox, Deepgram, and OpenAI adapters + the settings toggle/language picker are
  implemented; AssemblyAI remains a candidate.
- **Phase 4 (optional) — in-place revision:** AX-first → keystroke-backspace → clipboard
  fallback chain for low-churn revision; add the Accessibility TCC request.

### Risks / open questions

- **ElevenLabs token requirement:** confirm whether realtime *requires* a single-use token
  even when you hold the key (would need one REST call pre-connect).
- **Soniox limits:** 300-min hard session cap + 10 concurrent default — fine for single-user
  dictation, but the session cap means very long continuous dictation needs a reconnect.
- **AssemblyAI billing:** charged on connection-open time — must `Terminate` promptly when
  dictation ends (don't leave idle sockets open).
- **Speechmatics:** no realtime auto language detection (language must be set per session).
- **Endpointing defaults vary** by provider/model and several docs disagree — tune
  empirically (dictation sweet spots noted: Speechmatics 0.8–1.2 s, Soniox manual-finalize
  after ~200 ms trailing silence, Deepgram `endpointing` ~300–500 ms).
- **Latency claims are vendor-reported**, not independent — validate the shortlist with a
  real mic before committing to a default.
- **Reson8 maturity:** thin docs, no SDK, no published latency — treat as
  privacy-niche/experimental, not a default.

---

## 8. Sources

Primary docs (per provider): Reson8 `docs.reson8.dev`; Soniox `soniox.com/docs/stt`;
ElevenLabs `elevenlabs.io/docs` (Scribe v2 Realtime); Cartesia `docs.cartesia.ai/…/stt`;
Deepgram `developers.deepgram.com` (Nova-3 streaming); AssemblyAI `assemblyai.com/docs`
(Universal-Streaming v3); Speechmatics `docs.speechmatics.com` (RT/Ursa); Gladia
`docs.gladia.io` (Live v2 / Solaria); OpenAI `developers.openai.com/api/docs`
(Realtime transcription / `gpt-realtime-whisper`).

Engineering / UX references: Apple `URLSessionWebSocketTask`, `CGEvent`,
`keyboardSetUnicodeString`, `kAXSelectedTextAttribute`; AWS Transcribe partial-results
stabilization; Wispr Flow accessibility/insertion docs; fluidvox "how AI dictation works".

Pricing/latency figures are vendor-reported as of 2026-06; verify in each dashboard before
relying on them.
