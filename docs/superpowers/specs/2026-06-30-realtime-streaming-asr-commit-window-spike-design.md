# Streaming-dictation commit-window spike — design

> **Status:** approved design, pre-implementation.
> **Date:** 2026-06-30.
> **Milestone:** 1 of N toward live streaming dictation. This milestone ships **no
> provider** — it de-risks the part that decides whether the whole feature is viable.
> **Background:** `docs/realtime-streaming-asr-research.md` (provider comparison +
> feasibility). Read §5 ("continuous pasting") there for the UX rationale this spec acts on.

---

## 1. Why this milestone exists

The goal feature is live dictation: words appear in the frontmost app as you speak, with
minimal delay. Research concluded the WebSocket/provider plumbing is low-risk and the audio
format is already produced by `DictationWAVWriter`. The genuinely uncertain part is the
**UX of inserting a *revising* transcript stream into another app without flicker** — the
"commit-window + continuous pasting" problem. If that doesn't feel good, the feature is
worthless regardless of which provider we pick.

So milestone 1 builds and evaluates exactly that, driven by **simulated** transcript chunks
(hand-authored fixtures), with **no real provider**. The output is a **go/no-go decision**
plus a chosen insertion strategy and commit-window policy to carry into milestone 2.

## 2. Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| What to build first | The commit-window + insertion engine, fed by simulated chunks | The risky part; provider streaming is "the easy part" and is deferred |
| Deliverable | Interactive harness **+** unit tests | Harness to judge real flicker/latency feel; tests to pin the pure logic |
| Insertion mechanism | **Both** behind an `InsertionStrategy` switch | Comparing the two ends of the latency↔flicker tradeoff *is* the de-risking |
| Simulated source | Hand-authored fixtures (revisable + immutable families) | Deterministic, no provider needed, full control of edge cases |
| Architecture | Pure-core in `DictationCore` (SPM-tested); AppKit at edges | Risky logic deterministically tested in the fast autonomous suite |
| Commit output shape | `CommitController` emits the **full committed string** | Lets each strategy decide append vs in-place; makes append-only's failure mode measurable |
| Harness entry | DEBUG-only Debug-menu command with focus countdown | Keeps the spike out of the real hotkey/`DictationCoordinator` flow |

## 3. Goal & non-goals

**Goal.** A developer can pick a fixture + strategy + commit policy from a DEBUG menu, focus
a target app (e.g. TextEdit), and watch simulated dictation stream in — while the existing
overlay shows the volatile (uncommitted) tail. Unit tests pin the commit-window and diff
logic. Metrics make the two strategies comparable.

**Non-goals (YAGNI — explicitly out of scope, later milestones):**
- Real WebSocket / any provider; minting tokens; network code.
- Feeding live captured audio into the stream.
- Accessibility (`AXUIElement`) in-place insertion — Post-Event access only here.
- Settings UI, provider abstraction (`RealtimeSTTProvider`), persistence of choices.
- Changing the real `DictationCoordinator` / hotkey / `BatchTranscriber` flow.

## 4. Architecture

Mirrors the existing module split: `DictationCore` is `nonisolatedSettings` pure logic
(already home to `DictationStateMachine`, `ModifierGestureRecognizer`); the app target owns
AppKit-touching code (`TextInserter`, `DictationOverlayController`, menus).

```
[SimulatedTranscriptSource]            DictationCore (pure, nonisolated, SPM-tested)
   replays fixture on a Task
   → onPartial(String) / onFinal(String)   ← existing DictationTranscriber seam (output side)
            │  (hop to MainActor at the harness boundary)
            ▼
[CommitController]                     DictationCore (pure, synchronous, SPM-tested)
   update(partial:) / finalize(_:)
   → onVolatileChanged(tail)  ──────────────→ DictationOverlayController   (app target)
   → onCommitChanged(committed) ───────────→ [InsertionStrategy]           (app target)
                                                   ClipboardAppendInserter
                                                   KeystrokeDiffInserter → frontmost app
   [StreamingSpikeHarness] (@MainActor, DEBUG) wires fixture × strategy × policy, collects metrics
```

### 4a. Pure core — `DictationCore`

- **`SimulatedTranscriptScript`** (`Codable`): `{ events: [ScriptEvent] }`,
  `ScriptEvent = { delayMs: Int, kind: ScriptKind }`, `ScriptKind = .partial(String) |
  .final(String)`. `.partial` carries the **cumulative current hypothesis** (not a delta) —
  the common denominator across providers. Fixtures are JSON resources in the module bundle.
  Ship at least two:
  - **revisable** — partials that rewrite the tail (e.g. "i want" → "I wanted to", late
    punctuation/capitalization), then a `.final`.
  - **immutable/append-only** — partials grow monotonically; each `.final` only appends.
- **`SimulatedTranscriptSource: DictationTranscriber`** — conforms to the existing seam;
  `transcribe(audioFile:onPartial:onFinal:)` ignores `audioFile`, replays the script
  honoring `delayMs`, invoking `onPartial`/`onFinal`. **Sleep is injected** (default
  `Task.sleep`) so tests run instantly — mirrors `SonioxAsyncHandler`'s injectable
  `pollInterval`/`deadline`. *(The seam's input side, `audioFile` vs a live buffer stream,
  is a real-provider concern deferred to milestone 2; we exercise only the output side.)*
- **`CommitController`** — the core. API: `update(partial: String)`, `finalize(_ text:
  String)`. State: `committedText` and a stability window over the volatile tail. Policy:
  **commit the longest prefix that has been stable across `K` consecutive partials**
  (`K` configurable; optional debounce by event count). `finalize` commits the whole
  segment text and resets volatile state for the next segment. Emits:
  - `onCommitChanged(committed: String)` — the full committed string whenever it changes.
  - `onVolatileChanged(tail: String)` — the uncommitted remainder (for the overlay).
  Pure and synchronous; no timers (the timeline lives in the source). Deterministic.
- **`reconcile(from old: String, to new: String) -> (backspaces: Int, insert: String)`** —
  longest-common-prefix diff: backspace the diverging suffix of `old`, then insert the
  diverging suffix of `new`. Pure helper; powers `KeystrokeDiffInserter` and flicker metrics.

### 4b. App-target edges (AppKit)

- **`InsertionStrategy`** protocol: `func apply(committed old: String, to new: String)`,
  `func reset()`. Both impls gate on the **Post-Event access** `TextInserter` already
  preflights (`CGPreflightPostEventAccess`/`CGRequestPostEventAccess`) — **no new
  permission**:
  - **`ClipboardAppendInserter`** — if `old` is a prefix of `new`, ⌘V-paste the suffix
    (`new` minus `old`) via the existing `TextInserter` clipboard path, marking the write
    transient (`org.nspasteboard.TransientType`). If `new` does **not** extend `old`
    (committed text was revised), it cannot reconcile → increments a **revision-miss**
    metric and leaves the target unchanged. This failure mode is intentionally surfaced, not
    hidden — it's what tells us whether append-only is good enough.
  - **`KeystrokeDiffInserter`** — `reconcile(old, new)` → post `backspaces` × Backspace
    (keycode 51) then type `insert` via `CGEvent.keyboardSetUnicodeString`. Handles in-place
    revision; never touches the clipboard.
- **`StreamingSpikeHarness`** (`@MainActor`, DEBUG-only) — wires one *fixture × strategy ×
  commit-policy* run. The source replays on a background `Task`; its callbacks **hop to
  MainActor** before touching `CommitController`/UI — deliberately exercising the
  off-thread→MainActor handoff the real streaming path will need (the `ResultRef` caveat at
  `DictationCoordinator.swift:233-237`). Routes `onVolatileChanged` to an overlay (the
  volatile tail) and `onCommitChanged` to the chosen `InsertionStrategy`. Collects
  **metrics**: time to first committed word, total backspaces emitted, revision-misses,
  total run duration.
  - *Overlay note:* `DictationOverlayController` is currently a status/level HUD, so showing
    transcript text likely needs a small text-rendering addition to it, or a minimal
    DEBUG-only overlay. Presentation detail — not core to the spike's go/no-go; pick whatever
    is least invasive at implementation time.
- **Trigger** — a DEBUG-only Debug-menu command, `Run streaming spike ▸ {fixture} ▸
  {strategy}`, with a ~3 s countdown so the developer can focus a target app before replay
  begins. Independent of the real hotkey/`DictationCoordinator` path.

### 4c. Tests — SPM, `DictationCoreTests`

- **`CommitControllerTests`** — drive scripted `update`/`finalize` sequences; assert
  `committed`/`volatile` after each step. Cases: monotonic growth (no committed churn); tail
  revised *before* stabilization (still no committed churn); tail revised *after* it was
  committed (committed string changes — the hard case the strategies diverge on); `finalize`
  flush; multiple segments in one run.
- **`ReconcileTests`** — append-only, replace-suffix, full-replace, empty `old`, empty `new`,
  identical strings.
- **`SimulatedTranscriptSourceTests`** — with an injected instant clock, asserts events are
  emitted in order with correct partial/final kinds; fixture JSON decodes.

### 4d. Error handling

- Post-Event access denied → harness surfaces a message and falls back to clipboard-only
  (leave committed text on the pasteboard), mirroring `TextInserter`'s existing
  `clipboardFallback`.
- Fixture decode failure → logged to `LogStore` (the existing in-app Logs surface).
- All UI and insertion happen on `MainActor`; only the replay timeline runs off-main.

## 5. Success criteria / exit

1. From the Debug menu, choosing a fixture + strategy + policy and focusing TextEdit shows
   simulated dictation appearing in TextEdit, with the overlay showing the volatile tail.
2. `CommitController` and `reconcile` behavior is pinned by passing `DictationCoreTests`
   (`swift test --disable-sandbox --package-path Packages/AudioPipeline`), and the app target
   still builds.
3. The metrics + hands-on feel yield a **go/no-go decision** and, if go, a chosen insertion
   strategy + commit-window `K`/debounce to carry into milestone 2.

## 6. Follow-on milestones (context, not part of this spec)

2. Real provider: a `DictationTranscriber` conformer using `URLSessionWebSocketTask` against
   one provider (Soniox/Deepgram), fanning the existing 16 kHz mono Int16 buffers to the
   socket; same `CommitController` + strategy downstream. Resolve the seam's input side
   (live buffers vs `audioFile`).
3. Provider abstraction (`RealtimeSTTProvider`) + 2–3 adapters + settings UI.
4. (Optional) AX-first in-place insertion fallback chain.

## 7. Findings & verdict (2026-07-01)

**Verdict: GO.** The commit-window + continuous-pasting mechanism works. M1 built the engine
(pure `DictationCore`: `reconcile`, `CommitController`, `SimulatedTranscriptSource`, model +
fixtures; app-target `InsertionStrategy` + clipboard/keystroke inserters; DEBUG harness +
overlay + menu). All tasks passed spec+quality review; final whole-branch review returned no
Critical/Important defects; SPM suite 380 green; Debug + Release both build.

Headless run of all five combos (real `CommitController` + `reconcile` + the shipped fixtures,
driven through each inserter's exact decision rule; side-effects mocked) — reproduces the
review's hand-trace exactly:

| Combo | Final text | Result | Metrics |
|---|---|---|---|
| Revisable × Clipboard (k=2) | `"I think "` | WRONG | revisionMisses=3, appended=8 |
| Revisable × Keystroke (k=2) | `"I thought it is fine."` | correct | backspaces=9, revised=1, appended=30 |
| Revisable × Clipboard (k=3) | `"I thought it is fine."` | correct | revisionMisses=0, appended=21 |
| Immutable × Clipboard (k=2) | `"the quick brown fox."` | correct | clean |
| Immutable × Keystroke (k=2) | `"the quick brown fox."` | correct | clean |

**Live TextEdit run (manual):** all five felt acceptable; the **revising (keystroke /
in-place backspace-diff) strategy felt best**.

**Decisions carried into M2 (real provider):**
- **Default insertion strategy: keystroke / in-place revision.** It types the live hypothesis
  and backspace-diffs corrections, so it always converges to the correct text regardless of the
  commit window, and it was the preferred feel.
- **Keep clipboard append-only as a fallback** for targets where synthetic keystrokes/backspacing
  are unreliable. When used, the commit window `k` must be tuned to the provider's revision depth —
  too low and it silently drops mid-utterance corrections (the k=2 `revisionMiss` case above).
- **Interpretation notes for the metrics:** `revisionMisses` counts *events that could not apply*,
  not distinct revisions (one logical "think→thought" revision yields 3 misses because `applied`
  intentionally doesn't advance on a miss). `stabilityCount` (`k`) affects only the clipboard path;
  keystroke consumes the full hypothesis regardless of `k`.
- The `DictationTranscriber` seam's *input* side (live audio buffers vs `audioFile`) is still the
  open M2 design point; the *output* side (`onPartial`/`onFinal` → commit window → strategy) is
  proven here.
