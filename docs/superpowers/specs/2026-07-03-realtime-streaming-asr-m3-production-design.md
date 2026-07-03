# Realtime streaming ASR — M3: production integration (design)

**Date:** 2026-07-03
**Branch:** `research/realtime-streaming-asr` (worktree)
**Predecessors:** M1 commit-window spike (`docs/superpowers/specs/2026-06-30-realtime-streaming-asr-commit-window-spike-design.md`, GO) · M2 Reson8 Realtime spike (`docs/superpowers/specs/2026-07-01-reson8-realtime-streaming-spike-design.md`, GO)

## 1. Context & goal

Two spikes proved the two hard parts of live dictation and both got a GO verdict:

- **M1** proved the *output* side — `reconcile` → `CommitController` (stability window) → `InsertionStrategy`. Decision: **keystroke/in-place revision is the default** (always converges regardless of commit window, best feel); clipboard append-only is a fallback.
- **M2** proved the *input* side — live mic → `wss://api.reson8.dev` → interim/final transcripts → commit window → words appear live in the frontmost app. Direct `Authorization: ApiKey <key>` auth, `pcm_s16le`/16 kHz/mono format fit.

Both are wired **only into a DEBUG menu** (`Reson8SpikeHarness`, `StreamingSpikeHarness`). M3 graduates the proven path into the real dictation flow, introduces a `RealtimeSTTProvider` abstraction, adds a **second adapter (Soniox)** to prove the abstraction isn't Reson8-shaped, and adds the settings surface.

**Success criteria:** the user configures a streaming-capable provider, flips a "Stream results live" toggle, presses the real dictation hotkey, and words appear live in the frontmost app — driven through the same `DictationCoordinator`/`DictationStateMachine` as batch dictation, with the off-thread→MainActor hop applied in the shipping path.

## 2. Locked decisions

- **Milestone shape:** Full M3 — real-flow integration + abstraction + second adapter + settings.
- **Second adapter:** **Soniox** (revisable partials → commit window reused; connects to its own `wss` host and sends a JSON config-first message carrying the api_key → in-band auth, deliberately unlike Reson8's header auth / immediate binary).
- **Batch vs streaming selection:** **capability-gated toggle over a single provider.** One "Dictation provider" picker; a "Stream results live" toggle enabled only when the selected provider has a realtime conformer. Streaming-capable providers can still do batch, so the toggle is a real liveness-vs-accuracy choice.
- **Abstraction (Approach A):** a distinct `RealtimeSTTProvider` + `RealtimeSTTSession` + `TranscriptEvent`, parallel to `DictationTranscriber`. Batch stays untouched. Rejected: unifying both under one `AsyncStream<Data>`-input protocol (leaky — `BatchTranscriber` wraps `AudioJobSending`, which needs a *file*; the session lifecycle and config-message don't fit a bare stream-in).
- **Callback shape:** a single `onEvent(TranscriptEvent)` (partials/finals) + a separate `onError`. The unified event maps 1:1 onto the single `AsyncStream` MainActor bridge the DEBUG harness already uses.

## 3. The streaming seam (`DictationCore`)

New, pure, unit-testable types alongside `DictationTranscriber.swift`:

```swift
public enum TranscriptEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

public protocol RealtimeSTTSession: Sendable {
    func start()                 // open WS + send provider config
    func send(_ pcm: Data)       // called on the recorder's serial audio queue
    func finish() async          // flush + await trailing finals + close
}

public protocol RealtimeSTTProvider: Sendable {
    func makeSession(
        baseURL: URL,
        apiKey: String,
        language: String,
        onEvent: @Sendable (TranscriptEvent) -> Void,
        onError: @Sendable (Error) -> Void
    ) throws -> RealtimeSTTSession
}
```

`DictationTranscriber` (`transcribe(audioFile:onPartial:onFinal:)`) and `BatchTranscriber` are **unchanged**.

**Module placement:** the protocol + `TranscriptEvent` live in `DictationCore` (symmetry with `DictationTranscriber`). The concrete conformer adapters and the registry (§5) live in the **app target**, mirroring `BatchTranscriber` (which is app-target because it bridges `DictationCore` ↔ `AudioPipelineJobs`). The wire-level clients stay in `AudioPipelineJobs`.

## 4. State machine + coordinator

### 4.1 `DictationStateMachine` (`DictationCore`)

Add a **mode** and streaming transitions; leave batch transitions byte-for-byte unchanged.

```swift
public enum Mode: Sendable { case batch, streaming }

public enum Phase: Equatable, Sendable {
    case idle, listening, transcribing, inserting   // (existing, batch)
    case streaming, finalizing                       // (new)
}

public enum Action: Equatable, Sendable {
    case none, beginCapture, endCaptureAndTranscribe,
         insert(String), showError(String), showEmpty   // (existing)
    case beginStreamingCapture, endStreamingCapture       // (new)
}

public init(mode: Mode)
```

**Streaming transitions:**
- `startOrToggle()` — `idle → streaming` returning `.beginStreamingCapture`.
- `release()` / `startOrToggle()` (toggle up) — `streaming → finalizing` returning `.endStreamingCapture`.
- `finalized()` — `finalizing → idle` returning `.none`. (Insertion is continuous and coordinator-driven; there is no `.insert` action and no `transcriptReady` in the streaming path.)
- `failed(_:)` — any streaming phase → `idle` returning `.showError`, same as batch.

Batch transitions (`beginCapture → endCaptureAndTranscribe → transcriptReady → insert/showEmpty → inserted`) are unchanged.

### 4.2 `DictationCoordinator` (app target)

**Mode resolution:** on each `settingsChanged()` re-arm, mode = `.streaming` iff `dictation.streamLive` **and** the selected provider has a realtime conformer (§5); otherwise `.batch`. The machine is (re)constructed with that mode.

**Streaming capture path:**
1. On `.beginStreamingCapture`: resolve provider + Keychain key + `dictation.language`; `session = provider.makeSession(baseURL:apiKey:language:onEvent:onError:)`; `session.start()`; start `DictationRecorder(url:onLevel:onChunk: { session.send($0) })`. The temp WAV is still written by `DictationWAVWriter` (its `onChunk` fan-out already coexists with file writing — no new fan-out infra); it is kept/deleted per `keepAudio` exactly as batch does.
2. Off-thread `onEvent`/`onError` are bridged onto the MainActor via an `AsyncStream<TranscriptEvent>` consumed by a `Task { @MainActor … }` — **this is the shipping form of the `ResultRef` hop** the M2 findings flagged (`DictationCoordinator.swift` ~line 233–237). `ResultRef` stays exactly as-is for the batch path, which is correct because batch `onFinal` fires once synchronously.
3. Each event drives `CommitController.update(partial:)` / `finalize(_:)` → `InsertionStrategy.apply(committed:fullHypothesis:)` → live insertion.
4. On `.endStreamingCapture`: `await session.finish()` (flush + trailing finals continue to drive the commit controller), then `machine.finalized()`.

**Insertion strategy:** **keystroke/in-place fixed** (`KeystrokeDiffInserter`, M1's proven default). No configurable strategy setting in M3; `ClipboardAppendInserter` remains available in code as the documented fallback.

**Overlay:** reuse the existing `DictationOverlayController` to show the volatile tail during `streaming` (gated by the existing `showOverlay`), replacing the spike's `SpikeOverlayPanel`.

## 5. Provider capability + config

Two conformers of `RealtimeSTTProvider` (app target):
- `Reson8RealtimeProvider` — adapts the existing `Reson8RealtimeClient` (header auth; derives `wss` from `provider.baseURL` via `Reson8RealtimeURL.make`; `language` replaces the current `en` constant in `Reson8RealtimeOptions`).
- `SonioxRealtimeProvider` — new (§6).

**Capability = registry membership.** A small registry `realtimeProvider(for presetID: String) -> RealtimeSTTProvider?` is the single source of truth. The Settings toggle is enabled iff the selected provider's `presetID` resolves. **No `Preset`/`presets.json` schema change and no new `JobShape` are required** — capability is derived, not declared.

**No keyless carve-out.** Both providers use API keys, so `JobRunner.swift:39` (unconditional key fetch) and `ProviderEditorView.swift:84` (key mandated) are correct as-is for streaming providers. (The keyless carve-out belongs to the separate local-transcription track, not this one.)

## 6. Soniox adapter (`AudioPipelineJobs`)

A Reson8-parallel trio, wire-level and SPM-tested, behind `RealtimeSTTProvider`:
- `SonioxRealtimeURL` — builds the Soniox realtime `wss` endpoint (its own host, not derived from the batch `baseURL`).
- `SonioxRealtimeStreamDecoder` — pure `String → TranscriptEvent`-shaped decode of Soniox token messages (tokens carry `is_final`); never throws (malformed → ignored), mirroring `Reson8StreamDecoder`.
- `SonioxRealtimeClient` — `@unchecked Sendable` WS client. `start()` sends the JSON config first message (api_key, model, `pcm_s16le`/16 kHz/mono, language, include-non-final tokens), then `send(_:)` streams binary PCM, `finish()` sends the end sentinel and awaits trailing finals before normal-closure cancel.

`SonioxRealtimeProvider.makeSession` wraps this client and maps its callbacks to `onEvent`/`onError`. Per §3/§5 the **trio lives in `AudioPipelineJobs`** (wire-level, SPM-tested) while the **`SonioxRealtimeProvider` conformer + its registry entry live in the app target**, alongside `Reson8RealtimeProvider`.

## 7. Settings

`DictationSettings` (`DictationCore/DictationSettings.swift`) gains two fields (persisted automatically via the existing `AppSettings` JSON blob):
- `streamLive: Bool = false`
- `language: String = "en"`

`SettingsView` Dictation section adds:
- **"Stream results live"** toggle — disabled with an explanatory caption when the selected provider has no realtime conformer.
- **"Language"** picker — a curated BCP-47 starter list (`en`, `es`, `fr`, `de`, `it`, `pt`, `nl`), extendable; drives the streaming session's `language`. Providers map/validate their own supported codes.

Both route through the existing `dictation.settingsChanged()` hook. The existing dictation provider picker is unchanged.

## 8. Testing

- **SPM (deterministic, `DictationCore` + `AudioPipelineJobs`):**
  - New `DictationStateMachine` streaming transitions (mode, `streaming`/`finalizing`, `beginStreamingCapture`/`endStreamingCapture`/`finalized`).
  - A fake `RealtimeSTTSession` emitting scripted `TranscriptEvent`s to exercise the event → `CommitController` → `InsertionStrategy` loop (analogous to `SimulatedTranscriptSource` for batch).
  - Pure `SonioxRealtimeURL` + `SonioxRealtimeStreamDecoder` unit tests, mirroring the existing Reson8 URL/decoder tests.
- **App-hosted / DEBUG:** live WebSocket stays manual — retain a DEBUG smoke path. After SPM green, **rebuild the app target** (`xcodebuild … build`) per `CLAUDE.md` (a green SPM suite is not proof the app compiles).

## 9. Out of scope (YAGNI)

Batch-path behavior changes; keyless providers; a configurable insertion-strategy setting; AX-first insertion fallback; manual-stop / endpointing tuning; the Reson8 Turns low-latency endpoint; batch-mode language selection. Deferred polish from the M2 findings (suppress the benign shutdown-cancel log line; `send` backpressure under network stalls; `Reson8RealtimeURL.path` → `internal`) is optional cleanup, not gating.

## 10. Risks & open implementation notes

- **Module dependency direction:** conformers are placed in the app target to avoid forcing `AudioPipelineJobs` → `DictationCore`. If that import already exists (verify), the adapters *may* move into `AudioPipelineJobs`; the app-target placement is the safe default and matches `BatchTranscriber`.
- **Soniox wire details** (config field names, end-sentinel, token JSON shape) must be confirmed against Soniox's realtime WS docs during implementation; the trio's structure is fixed, the field-level specifics are the unknown.
- **`send` on the audio queue:** `session.send` runs on the writer's serial queue; conformers must keep it non-blocking (Reson8's client already does — fire-and-forget WS frame).
