# Job Runner Follow-Ups

Two pre-existing defects found during manual verification of PR #6 (App Sandbox
productionization). Both are orthogonal to the sandbox work and were deliberately
deferred to their own branches.

---

## 1. Job observability — no per-job / in-flight tracking

**Symptom (user-reported):** Start a job on a long recording, then start a second
job on a short recording. The short one finishes and delivers its transcript; the
first appears to "vanish" — no running indicator, no transcript, no terminal log.

**Root cause (not a lost task):** the first job was still running. There is no
per-job status model:

- `AppCoordinator.jobActivity: String?` is a **single shared transient slot**. It's
  set directly to `"Running…"` (no auto-clear) and via `flashActivity` (3 s
  auto-clear) for `"Done/Failed"`. A second job overwrites the first's only
  indicator.
- Each "Run Job" press spawns an **independent unstructured `Task {}`**
  (`RecordingsView.swift`) with no stored reference and no registry — so jobs run
  concurrently, but nothing tracks or displays more than one.

**Evidence:** the unified log showed the "vanished" job was a Gemini
chat-completions request in-flight for ~7.6 min (`latency: 456930` ms); it logged
`Failed` only after the user had stopped looking.

**Proposed direction (needs a design pass — this is a feature, not a patch):**

- A per-job in-flight model (id, name, recording, state, started-at) owned by the
  coordinator, not a single string.
- A way to see running jobs (sidebar list / panel) so concurrent and long jobs are
  visible.
- Consider cancellation and a basic queue while we're in there.

**Start with:** the brainstorming skill — the UX and the state model are the open
questions, not the mechanics.

---

## 2. Opaque decode failure on empty `choices`

**Symptom:** a transcription job fails with
`Chat completions: could not decode the response: {…full JSON…}`.

**Root cause:** the provider returned `{"choices": null, …}`. In the observed case
`gemini-3.5-flash` (a reasoning model) spent its entire ~65 k output-token budget on
reasoning (`reasoning_tokens: 62910`) over a large audio input
(`audio_tokens: 82851`) and produced no content. The chat-completions handler has no
`choices[0]`, so its decode throws — hiding the real cause.

**Proposed fix (contained):**

- Detect null/empty `choices` before decoding and surface a clear error, e.g.
  "provider returned no content (the model may have hit its output-token limit)".
- Separately: a reasoning model via chat-completions on large audio is a poor fit —
  worth steering presets away from it for long recordings. See
  `docs/...` notes on combined-track sizing.

---

_Source: PR #6 manual verification, 2026-06-19._
