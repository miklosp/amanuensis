# Non-blocking recording finish — design

**Date:** 2026-05-27
**Status:** Approved (brainstorming)
**Scope:** M2 polish

## Goal

When the user stops a recording, the UI freezes until the CAF→FLAC conversion completes. Fix this so:

1. The new recording row appears in the Recordings panel immediately, before conversion runs.
2. A status footer indicates conversion progress, modelled on the existing `jobActivity` footer.
3. The conversion runs off the main actor at lower priority so neither the app nor the system becomes unresponsive.
4. If the user triggers `Run Job` on a recording whose conversion is still in flight, the job waits for the conversion to finish, then runs.

## Current state

- `AppCoordinator.stopRecording()` (`audio-pipeline/AppCoordinator.swift:126`) spawns `Task { @MainActor in await self.runCombinedExport(folder) }`. `runCombinedExport` is implicitly `@MainActor` (the type is).
- `CombinedFLACExporter.combine(...)` is `nonisolated static async` (`Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift:16`). Its header comment claims "Runs off the main actor."
- The `RecordingCore` SPM target enables `NonisolatedNonsendingByDefault` (SE-0461). Under that feature, a `nonisolated async` function inherits the caller's actor by default. Calling `combine` from a `@MainActor` context therefore executes the whole mix-and-encode on the main thread — that's the freeze. The header comment is stale and misleading.
- `RecordingSession.stop()` (`Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift:44`) writes `meta.json` from a `Task.detached` (line 70) — fire-and-forget.
- A folder needs a valid `meta.json` to show up in the Recordings panel (`RecordingsLibrary.refresh` filters via `RecordingItem.init?(folderURL:)`, which returns nil without it — `RecordingsLibrary.swift:51-56`).
- The Recordings footer renders `coordinator.jobActivity` (`RecordingsView.swift:73-88`). `AppCoordinator.flashActivity(_:)` provides a transient ~3 s display.

## Decisions

- **Off-main conversion via `Task.detached(priority: .utility)`.** Explicit at the call site beats `@concurrent` annotation on the exporter — the boundary is clearer in the orchestrator that owns it.
- **Synchronous `meta.json` write** in `RecordingSession.stop()`. Removes the race between the immediate `library.refresh()` and metadata landing. The payload is a few KB; one synchronous JSON encode + file write is not a perf concern at stop.
- **Two parallel footer fields.** `recordingActivity` for conversion; `jobActivity` (existing) for jobs. They can co-occur (job on recording A while recording B is converting). The footer renders both, stacked, when both are non-nil.
- **`runJob` waits on `pendingConversion`.** When called against the still-converting recording, set `jobActivity` to a waiting message and `await pendingConversion.task.value` before the existing `combined.flac` existence check.
- **Single conversion at a time.** The `RecorderStateMachine` already serializes via `.stopping`; one `pendingConversion` slot is enough.
- **No cancellation.** If the app quits during conversion, behave as today (task is dropped). Cancellation UI is out of scope.

## Components

### `AppCoordinator` (`audio-pipeline/AppCoordinator.swift`)

- **New properties:**
  - `var recordingActivity: String?` — observable, parallels `jobActivity`.
  - `private var pendingConversion: PendingConversion?` where `PendingConversion` is a private nested type holding `folderName: String` and `task: Task<Void, Error>`.
- **New method:** `private func flashRecordingActivity(_:)` — mirrors the existing `flashActivity(_:)` (3 s, snapshot-guarded clear).
- **`stopRecording()` rewritten:**
  1. `machine.stop()` and `session.stop()` as today.
  2. `_ = machine.sessionStopped(folderURL: folder.url)` as today.
  3. `library.refresh()` — synchronous, row now appears.
  4. `recordingActivity = "Converting recording…"`.
  5. Spawn `let task = Task.detached(priority: .utility) { try await CombinedFLACExporter.combine(mic:, system:, to:) }`.
  6. Store `pendingConversion = .init(folderName: folder.name, task: task)`.
  7. Wrap the post-conversion work in a separate `Task { @MainActor in ... }` that does `try await task.value`, deletes source CAFs if `!settings.keepOriginalCAF`, runs `machine.conversionFinished(...)`, `library.refresh()`, clears `pendingConversion` and `recordingActivity`, and calls `flashRecordingActivity("Recording ready")` on success or `flashRecordingActivity("Conversion failed: …")` on failure.
- **`runJob(_:on:)` adjusted:** at the top, if `pendingConversion?.folderName == recordingFolder.lastPathComponent`, set `jobActivity = "Waiting for '\(recordingName)' to finish converting…"` and `try? await pendingConversion?.task.value`. Then continue with the existing combined.flac check and runner.

### `RecordingSession` (`Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift`)

- **`writeMetadata` becomes synchronous.** Drop the `Task.detached` wrapper at lines 70-76; call `metadata.write(to: url)` directly inside `writeMetadata`. Errors logged as today.

### `CombinedFLACExporter` (`Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift`)

- **Comment fix only.** Replace the "Runs off the main actor" line with an accurate note: caller must dispatch this off the main actor (e.g. via `Task.detached`); under `NonisolatedNonsendingByDefault` a `nonisolated async` function inherits the caller's actor.

### `RecordingsView` (`audio-pipeline/UI/RecordingsView.swift`)

- **Second status row** identical in styling to the existing `jobActivity` block, bound to `coordinator.recordingActivity`. Renders below the table. When both are non-nil they stack with `recordingActivity` on top and `jobActivity` below (conversion is the closer-in-time event since the stop just happened). Same `ProgressView()` + `.callout` text + `.bar` background + bottom-edge transition. Animation value extended to also watch `coordinator.recordingActivity`.

## Data flow

```
User stops recording
  │
  ▼  (MainActor)
session.stop()                       ← writes meta.json synchronously now
machine.sessionStopped(...)
library.refresh()                    ← row appears, format = "CAF"
recordingActivity = "Converting…"
  │
  ▼  (Task.detached, .utility QoS)
CombinedFLACExporter.combine(...)    ← off main, lower priority
  │
  ▼  (Task { @MainActor in await task.value })
delete source CAFs if !keepOriginalCAF
machine.conversionFinished(.success)
library.refresh()                    ← row updates, format = "FLAC"
pendingConversion = nil
flashRecordingActivity("Recording ready")
```

If `runJob` is invoked on the converting folder before step `await task.value` resolves, it awaits the same task before its own combined.flac check.

## Error handling

- **Conversion failure:** `machine.conversionFinished(.failure(error))` (state machine returns to idle with `lastError` set), `flashRecordingActivity("Conversion failed: \(error.localizedDescription)")`, `pendingConversion = nil`. The row remains visible (it has CAF audio; `combined.flac` is absent).
- **`runJob` on a failed conversion:** `try?` swallows the error from `task.value`, then the existing `FileManager.default.fileExists(atPath: target.path)` check catches the missing `combined.flac` and returns `.failure(.combinedFlacMissing)` with the existing footer flash.
- **`meta.json` write failure at stop:** logged as today; the row simply doesn't appear (no recovery path here, same as before).

## Tests

- **SPM, `RecordingCoreTests`:** new case in `RecordingSessionTests` (creating one if absent) — call `stop()` and assert `FileManager.default.fileExists(atPath: folder.metadataURL.path)` is true on return. This locks in the synchronous-write decision.
- **No other test additions.** The `AppCoordinator` plumbing (footer fields, pendingConversion, await-on-conversion) is `@MainActor` app-target code and is verified manually:
  - Stop a recording → row appears immediately, footer shows "Converting…", UI stays responsive.
  - Wait → footer flashes "Recording ready", format column flips to FLAC.
  - Stop a recording → immediately Run Job on it → footer shows "Waiting for … to finish converting…", then runs once conversion completes.
  - Force a conversion failure (e.g. delete the mic CAF mid-conversion in a debug build) → footer shows the failure flash; row remains.

## Out of scope

- Cancellation of in-flight conversion (quit-while-converting, user-initiated).
- Per-row spinner / disabled state during conversion.
- Parallel conversions (state machine already serializes).
- Restructuring the existing `flashActivity` helpers into a shared queue.

## Amendment 2026-05-27: async writer drain

Manual verification surfaced a second main-thread blocker not addressed by the original design: the audio file writer drain. `AudioFileWriter.close()` calls `queue.sync { ... }` on the writer's serial dispatch queue to finalize the `AVAudioFile`. Both `MicRecorder.stop()` and `ProcessTapRecorder.stop()` invoke it synchronously, and `RecordingSession.stop()` is `@MainActor` — so for long recordings (e.g. 4 minutes) where the ALAC encoder hasn't fully caught up to real-time, the drain blocks main for the catch-up duration. The off-main *conversion* fix above made the post-stop phase responsive, but the stop itself still freezes the UI proportional to the writer-queue backlog.

**Decision:** make the close path async end-to-end.

- `AudioFileWriter.close()` becomes `async`. The body wraps the queue work in `withCheckedContinuation` + `queue.async` — semantically equivalent to `queue.sync` (FIFO ordering preserved, prior enqueued writes drain before the close block runs) but the calling thread (main) is not blocked.
- `MicRecorder.stop()` and `ProcessTapRecorder.stop()` become `async` and `await writer.close()`.
- `RecordingSession.stop()` becomes `async` and awaits both child stops sequentially.
- `AppCoordinator.stopRecording()` (already `async`) awaits `active.stop()`.

The four `writer.close()` call sites in `AudioFileWriterTests` migrate to `await writer.close()` and the tests become async.

The double-close semantic is preserved: a second `await close()` returns the same `framesWritten` value as the first (the queue still drains, but `closed`/`file` are already set; `framesWritten` is unchanged by close).
