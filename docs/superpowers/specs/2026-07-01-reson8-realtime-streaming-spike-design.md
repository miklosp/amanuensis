# Reson8 Realtime streaming spike — design

> **Status:** approved design, pre-implementation.
> **Date:** 2026-07-01.
> **Milestone:** 2 of N toward live streaming dictation. This milestone ships **one hard-coded
> provider** (Reson8 Realtime) behind a DEBUG harness — it proves the *network + live-audio*
> half of the feature, reusing the commit-window/insertion engine milestone 1 already proved.
> **Background:** `docs/realtime-streaming-asr-research.md` (provider comparison + feasibility)
> and `docs/superpowers/specs/2026-06-30-realtime-streaming-asr-commit-window-spike-design.md`
> (M1 — the commit window + insertion strategies, verdict **GO**).

---

## 1. Why this milestone exists

M1 proved the hard part — inserting a *revising* transcript into another app without flicker —
using **simulated** transcript chunks. Its verdict was GO, with the **keystroke / in-place
backspace-diff** inserter chosen as the default. What M1 explicitly deferred (its §7 "open M2
design point") is the **input side of the seam**: feeding *live* audio to a real provider over a
WebSocket and getting real partials/finals back off-thread.

This milestone closes exactly that gap for one provider — **Reson8 Realtime** — and nothing more.
It swaps M1's `SimulatedTranscriptSource` for a real `wss://` connection driven by live mic audio,
while reusing M1's `CommitController`, insertion strategies, overlay, and metrics unchanged. The
output is a **go/no-go on the live network path** (latency + transcription quality with real
speech) before we touch the shipping hotkey/`DictationCoordinator` flow in a later milestone.

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Provider | **Reson8**, hard-coded | User's provider; batch handler already exists. No abstraction yet (YAGNI). |
| Endpoint | **Realtime** (`/v1/speech-to-text/realtime`), not Turns | Reson8's own docs: *"For regular live transcription, use Realtime."* Its `include_interim`/`is_final` partials map 1:1 onto `CommitController`. Turns emits only at turn boundaries — for voice-agent turn-taking, not dictation. |
| Deliverable | DEBUG harness (menu-launched) **+** SPM unit tests for the pure wire logic | Harness to judge real latency/quality/feel; tests to pin URL assembly + message decode. |
| Insertion default | **Keystroke / in-place** (M1's chosen default); clipboard `k=3` as a second menu variant | Carry M1's decision; keep the comparison available. |
| Audio encoding | **Raw PCM** `encoding=pcm_s16le`, no container | `DictationWAVWriter` already emits 16 kHz mono Int16 LE; explicit encoding skips format detection. |
| Auth | **`Authorization: ApiKey <key>`** from Keychain, sent directly on the WS | Desktop app holds the user's own key; tokens are browser-only. Mirrors `Reson8PrerecordedHandler`. |
| Language | Pinned `language=en` (a constant) | Docs: pinning beats auto-detect for short dictation utterances. Trivially changeable. |
| Audio fan-out | Extend `DictationWAVWriter`/`DictationRecorder` with an optional `onChunk` sink | Research §6.2 — fan converted buffers to the WS *in addition to* the file write; reuses the converter (incl. its `.inputRanDry` handling). No new capture/convert code. |
| Wire-logic home | `AudioPipelineJobs`, next to `Reson8PrerecordedHandler` | All Reson8 wire logic in one module; pure parts stay SPM-testable; keeps `DictationCore` provider-agnostic. |
| Stop model | **Fixed ~20 s capture window** | Deterministic; no global key monitor (which would need Accessibility). Manual stop deferred. |
| Harness scope | New `Reson8SpikeHarness` sibling to `StreamingSpikeHarness`, reusing M1's engine/overlay/metrics | Live source doesn't fit the script-driven harness cleanly; reuse everything downstream. |

## 3. Goal & non-goals

**Goal.** From the DEBUG "Streaming Spike" menu, a developer picks `Reson8 Realtime (Keystroke)`,
focuses a target app (e.g. TextEdit), speaks, and sees their **real speech** typed in live via the
keystroke inserter while the overlay shows the volatile tail; after a fixed window the segment is
flushed and finalized and metrics are logged. Pure URL-building and message-decoding logic is
pinned by SPM tests.

**Non-goals (YAGNI — explicitly out of scope, later milestones):**
- The `RealtimeSTTProvider` abstraction / any second provider.
- The **Turns** endpoint.
- Settings UI, a persisted "streaming enabled" toggle, a streaming provider picker.
- Changing the real `DictationCoordinator` / hotkey / `DictationStateMachine` / `BatchTranscriber`.
- Diarization, word/timestamp/confidence detail, custom models, patterns (all `include_*=false`).
- Reconnect / backoff, session-length handling, a manual stop UI.
- Accessibility (`AXUIElement`) in-place insertion — Post-Event access only, as in M1.

## 4. Architecture

Reuses M1's split: pure/deterministic logic in the SPM package (SPM-tested), AppKit and live I/O
at the edges. The only new *live* surfaces are one WebSocket driver and the mic→WS fan-out.

```
[DictationRecorder]  (RecordingCore)                         mic → 16 kHz mono Int16 LE
   installTap → DictationWAVWriter (converter)
   → onChunk(Data)  ─────────────────────────────┐          NEW: optional chunk sink
                                                  ▼
[Reson8RealtimeClient]  (AudioPipelineJobs, nonisolated)     owns URLSessionWebSocketTask
   start() → send(pcm) binary frames up
   receive loop → Reson8StreamDecoder → onPartial / onFinal
   finish() → flush_request → await flush_confirmation → close
            │  (hop to MainActor at the harness boundary — the real ResultRef fix)
            ▼
[CommitController]  (DictationCore, unchanged from M1)
   update(partial:) / finalize(_:)
   → volatileTail  ───────────────→ SpikeOverlayPanel        (app target, M1)
   → committed / fullHypothesis ──→ InsertionStrategy         (app target, M1)
                                        KeystrokeDiffInserter → frontmost app
   [Reson8SpikeHarness] (@MainActor, DEBUG) wires provider/key × mic × client × strategy, metrics
```

### 4a. Wire contract (Reson8 Realtime — from the docs)

- **Connect:** `wss://api.reson8.dev/v1/speech-to-text/realtime`. Host + scheme derived from the
  existing `reson8` provider's `baseURL` (`https://api.reson8.dev`), swapping `https`→`wss` and
  appending the path.
- **Header:** `Authorization: ApiKey <key>` (user's key from `KeychainStore`).
- **Query params (the whole config):** `encoding=pcm_s16le`, `sample_rate=16000`, `channels=1`,
  `include_interim=true`, `language=en`. All feature flags off.
- **Up:** raw PCM as **binary** WebSocket frames (`send(.data:)`). Frames arrive naturally at
  ~real-time from the mic tap (~85 ms / ~2.7 KB each after 16 kHz conversion) — no manual pacing.
- **Down (JSON text frames):**
  - `{"type":"transcript","text":T,"is_final":false}` → interim → `CommitController.update(partial: T)`
  - `{"type":"transcript","text":T,"is_final":true}` → final → `CommitController.finalize(T)`
  - `{"type":"flush_confirmation","id":…}` → shutdown handshake
  - Any other/unparseable message → ignored.
- **Shutdown:** send `{"type":"flush_request","id":"stop"}`, await a trailing final or the
  `flush_confirmation` (short timeout ~1 s), then close.
- **Liveness:** server sends WebSocket ping frames; `URLSessionWebSocketTask` answers them
  automatically. *(Verify via logging during implementation; if it does not auto-pong, add a
  periodic `sendPing`.)*
- **Errors:** connect/auth failures surface as a WS close / non-101 upgrade (401 `UNAUTHORIZED`,
  400 `INVALID_REQUEST`, 500 `INTERNAL_ERROR`) — logged and shown, then the spike stops.

### 4b. Pure core — `AudioPipelineJobs` (SPM-tested)

- **`Reson8RealtimeURL`** — builds the `wss://…` URL with query items from `(baseURL, options)`.
  Pure; deterministic ordering for stable tests.
- **`Reson8StreamEvent`** — `enum { case partial(String); case final(String);
  case flushConfirmed(id: String?); case ignored }`.
- **`Reson8StreamDecoder`** — `decode(_ json: String) -> Reson8StreamEvent`. Pure. Reads `type`,
  `text`, `is_final`; tolerates missing optional fields; returns `.ignored` for unknown types or
  malformed JSON (never throws — a stray frame must not kill the stream).

### 4c. Live edge — `AudioPipelineJobs`

- **`Reson8RealtimeClient`** — `nonisolated final class … : @unchecked Sendable`, owns one
  `URLSessionWebSocketTask`. API:
  - `init(url: URL, apiKey: String, onPartial: @Sendable (String) -> Void, onFinal: @Sendable (String) -> Void)`
  - `start()` — `resume()` the task and arm the receive loop (`receive` re-arming itself; each
    `.string` result → `Reson8StreamDecoder` → `onPartial`/`onFinal`).
  - `send(_ pcm: Data)` — non-blocking `send(_:completionHandler:)`; safe to call from the audio
    thread (URLSession serializes internally). Send errors are logged, not thrown.
  - `finish() async` — send `flush_request`, await the trailing final / `flush_confirmation` with a
    short timeout, then `cancel(with: .normalClosure)`.
  Untestable live I/O; the decode/URL logic it depends on is the tested part.

### 4d. Audio fan-out — `RecordingCore`

- **`DictationWAVWriter`** gains an optional `onChunk: (@Sendable (Data) -> Void)?`. Inside the
  existing converter block, after the `guard status != .error … out.frameLength > 0` check, copy
  the converted interleaved Int16 samples to `Data` and invoke `onChunk` — *in addition to* the
  file write. The chunk is exactly `pcm_s16le` (native Int16 LE on this platform). File writing is
  unchanged; the WAV remains a harmless debug artifact.
- **`DictationRecorder`** gains a matching `onChunk` init parameter, threaded to the writer.

### 4e. App-target edge — `Amanuensis/Dictation/Streaming/` (DEBUG)

- **`Reson8SpikeHarness`** (`@MainActor`, DEBUG-only) — mirrors `StreamingSpikeHarness`:
  1. Resolve the Reson8 provider (`providers.providers.first { $0.presetID == "reson8" }`) and its
     Keychain key; if absent → overlay flash + log, abort.
  2. Preflight Post-Event access (M1 pattern); show overlay; 3 s focus countdown.
  3. Build the URL (`Reson8RealtimeURL`), create `Reson8RealtimeClient` and `start()` it (opens the
     socket, arms the receive loop) *before* mic capture. Its `onPartial`/`onFinal` **hop to
     `MainActor`** (via an `AsyncStream` consumed on the harness, as M1's harness does) →
     `CommitController` → chosen `InsertionStrategy` (default `KeystrokeDiffInserter`) → target app;
     `volatileTail` → `SpikeOverlayPanel`.
  4. Start mic capture: `DictationRecorder(url: tempURL, onLevel:…, onChunk: { client.send($0) })`.
  5. Capture for a fixed window (~20 s), then stop the recorder, `await client.finish()`, delete the
     temp WAV, log metrics (reuse `SpikeMetrics`: first-word latency, backspaces, revision-misses,
     total ms), hide overlay.
- **Menu** — extend `StreamingSpikeCommands` with `Reson8 Realtime (Keystroke)` and
  `Reson8 Realtime (Clipboard k=3)`. The view needs `AppCoordinator` threaded in (for
  `providers`/`keychain`); pass it from `AmanuensisApp`.

### 4f. Tests — SPM, `AudioPipelineJobs`

- **`Reson8RealtimeURLTests`** — query assembly (all five params present, correct values),
  `https`→`wss` scheme swap, correct path, trailing-slash handling on `baseURL`.
- **`Reson8StreamDecoderTests`** — interim (`is_final:false`) → `.partial`; final (`is_final:true`)
  → `.final`; transcript with only `text` (defaults); `flush_confirmation` with and without `id`;
  unknown `type` → `.ignored`; malformed JSON → `.ignored`.

### 4g. Error handling

- No Reson8 provider / no key → overlay flash + `LogStore`, abort before connecting.
- WS connect/auth/stream failure → log full detail (status + reason) to `LogStore`, overlay flash,
  stop the spike (mirrors `Reson8PrerecordedHandler.SendError` full-detail messages).
- Mic unavailable / capture start fails → log + flash, abort (as `DictationCoordinator.beginCapture`).
- Post-Event access denied → M1's clipboard fallback path.
- All UI + insertion happen on `MainActor`; only mic capture and WS I/O run off-main.

## 5. Success criteria / exit

1. From the Debug menu, `Reson8 Realtime (Keystroke)` + focusing TextEdit types the developer's
   **real spoken words** into TextEdit live, with the overlay showing the volatile tail, and a
   final flush at the end of the ~20 s window.
2. `Reson8RealtimeURL` and `Reson8StreamDecoder` are pinned by passing `AudioPipelineJobs` SPM tests
   (`swift test --disable-sandbox --package-path Packages/AudioPipeline`), and the app target still
   builds (`xcodebuild … -scheme Amanuensis … build`).
3. Hands-on: latency (time-to-first-word) and transcription quality with real speech are judged
   acceptable → **go/no-go** on Reson8 Realtime as the live path to carry into M3.

## 6. Follow-on milestones (context, not part of this spec)

3. Integrate streaming into the real hotkey → `DictationCoordinator` → `DictationStateMachine`
   (send-while-recording; a new streaming phase; the `ResultRef` fix applied in the real flow).
4. `RealtimeSTTProvider` abstraction + a second adapter (e.g. Soniox/Deepgram) + settings UI +
   streaming provider picker.
5. (Optional) AX-first in-place insertion fallback chain; manual stop / endpointing tuning; the
   Turns endpoint for latency-critical scenarios.
