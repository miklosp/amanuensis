# Non-blocking recording finish — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop blocking the main thread during the CAF→FLAC conversion that runs at the end of a recording, surface the new recording row immediately, and add a footer progress indicator. Run Job calls against a still-converting recording wait for the conversion before executing.

**Architecture:** `RecordingSession.stop()` writes `meta.json` synchronously so the row is visible the moment stop returns. `AppCoordinator.stopRecording()` then refreshes the library, sets a `recordingActivity` footer message, and dispatches `CombinedFLACExporter.combine(...)` on a detached `.utility`-priority task. A separate `@MainActor` task awaits the conversion's completion and updates state. `runJob` checks a single `pendingConversion` slot on the coordinator; if the targeted recording matches, it awaits the conversion before its existing combined.flac check.

**Tech Stack:** Swift 6.2, SwiftUI, AVFoundation, `swift-testing`. SPM package `Packages/AudioPipeline/` for `RecordingCore`/`RecordingStorage`; app target for `AppCoordinator` and SwiftUI views.

**Spec:** `docs/superpowers/specs/2026-05-27-non-blocking-recording-finish-design.md`

**Files touched:**
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift` (drop the `Task.detached` wrapper in `writeMetadata`)
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift` (fix the stale "runs off the main actor" comment)
- Modify: `audio-pipeline/AppCoordinator.swift` (new fields, rewritten `stopRecording`, `runJob` waits on pending conversion)
- Modify: `audio-pipeline/UI/RecordingsView.swift` (add a second status row + extract a small subview)

**Test surface note:** The spec called for an SPM test that asserts `meta.json` exists after `RecordingSession.stop()` returns. `RecordingSession.init` constructs a `MicRecorder` (AVAudioEngine bound to live input hardware) and a `ProcessTapRecorder` (CoreAudio process tap), so it can't be exercised in headless SPM tests without a real audio device. The underlying `RecordingMetadata.write(to:)` is already covered in `RecordingStorageTests/RecordingMetadataTests`. The structural change (removing `Task.detached`) is verified by code review and by Task 7's manual end-to-end check. No new automated test in this plan.

---

### Task 1: Synchronous `meta.json` write at session stop

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift:52-77`

- [ ] **Step 1: Read the current `writeMetadata` to confirm the exact bytes you'll be replacing**

```bash
sed -n '52,77p' Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift
```

- [ ] **Step 2: Replace the `writeMetadata` body so the write runs synchronously**

In `Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift`, replace this block:

```swift
    private func writeMetadata(
        stoppedAt: Date?,
        mic: RecordingTrackResult?,
        system: RecordingTrackResult?
    ) {
        let started = startedAt ?? folder.startedAt
        let duration = stoppedAt.map { $0.timeIntervalSince(started) }
        let metadata = RecordingMetadata(
            folderName: folder.name,
            startedAt: started,
            stoppedAt: stoppedAt,
            durationSeconds: duration,
            mic: mic.map { Self.trackMetadata(from: $0) },
            system: system.map { Self.trackMetadata(from: $0) },
            hostAppVersion: Self.hostAppVersion,
            notes: nil
        )
        let url = folder.metadataURL
        Task.detached {
            do {
                try metadata.write(to: url)
            } catch {
                Self.log.error("metadata write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
```

with:

```swift
    private func writeMetadata(
        stoppedAt: Date?,
        mic: RecordingTrackResult?,
        system: RecordingTrackResult?
    ) {
        let started = startedAt ?? folder.startedAt
        let duration = stoppedAt.map { $0.timeIntervalSince(started) }
        let metadata = RecordingMetadata(
            folderName: folder.name,
            startedAt: started,
            stoppedAt: stoppedAt,
            durationSeconds: duration,
            mic: mic.map { Self.trackMetadata(from: $0) },
            system: system.map { Self.trackMetadata(from: $0) },
            hostAppVersion: Self.hostAppVersion,
            notes: nil
        )
        do {
            try metadata.write(to: folder.metadataURL)
        } catch {
            Self.log.error("metadata write failed: \(String(describing: error), privacy: .public)")
        }
    }
```

- [ ] **Step 3: Run the SPM test suite to confirm nothing regressed**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: `Test run with 102 tests in 22 suites passed`.

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift
git commit -m "$(cat <<'EOF'
fix(core): write meta.json synchronously at session stop

Removes the Task.detached wrapper so stop() returns only once meta.json is on
disk. AppCoordinator can then refresh the library immediately at stop without
racing the metadata write.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Correct the misleading comment on `CombinedFLACExporter`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift:4-8`

- [ ] **Step 1: Replace the file-level comment with one that's accurate under `NonisolatedNonsendingByDefault`**

In `Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift`, replace:

```swift
// Mixes mic + system tracks into a single 16 kHz mono FLAC by mono-summing in
// Float32 PCM, then encoding the mixed buffer to FLAC. Mic is required;
// system is optional (mic-only recordings happen when the system tap is
// denied or unavailable). Runs off the main actor; used after a recording
// stops.
```

with:

```swift
// Mixes mic + system tracks into a single 16 kHz mono FLAC by mono-summing
// in Float32 PCM, then encoding the mixed buffer to FLAC. Mic is required;
// system is optional (mic-only recordings happen when the system tap is
// denied or unavailable). Used after a recording stops.
//
// Callers MUST dispatch via `Task.detached` to keep this off the main actor:
// `nonisolated async` inherits the caller's actor under
// `NonisolatedNonsendingByDefault` (enabled for this target).
```

- [ ] **Step 2: Confirm SPM still builds**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/CombinedFLACExporter.swift
git commit -m "$(cat <<'EOF'
docs(core): correct CombinedFLACExporter isolation comment

The old comment claimed the function "runs off the main actor". Under
NonisolatedNonsendingByDefault, nonisolated async inherits the caller's actor,
so callers must explicitly dispatch via Task.detached.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `recordingActivity` field + `flashRecordingActivity` helper to `AppCoordinator`

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Add the observable `recordingActivity` property next to `jobActivity`**

In `audio-pipeline/AppCoordinator.swift`, find:

```swift
    var jobActivity: String?
```

(currently at line 49) and change it to:

```swift
    var jobActivity: String?
    var recordingActivity: String?
```

- [ ] **Step 2: Add a `flashRecordingActivity(_:)` helper mirroring the existing `flashActivity(_:)`**

In `audio-pipeline/AppCoordinator.swift`, find this method (currently lines 207-217):

```swift
    // Shows a transient activity message that auto-clears after ~3 seconds.
    // A subsequent runJob call replaces this immediately (no queue).
    private func flashActivity(_ message: String) async {
        jobActivity = message
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Only clear if our message is still the current one — a new run may
            // have replaced it.
            guard self?.jobActivity == snapshot else { return }
            self?.jobActivity = nil
        }
    }
```

Immediately after it, add:

```swift
    // Same auto-clear pattern as flashActivity, but for the recording-conversion
    // footer line.
    private func flashRecordingActivity(_ message: String) async {
        recordingActivity = message
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard self?.recordingActivity == snapshot else { return }
            self?.recordingActivity = nil
        }
    }
```

- [ ] **Step 3: Verify the app target still compiles**

Run: `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(coordinator): add recordingActivity footer state

Parallel field/helper to jobActivity for the upcoming recording-conversion
status line. No behaviour change yet; wired up in the next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Off-main conversion with a `PendingConversion` slot

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Add the `PendingConversion` type and storage**

In `audio-pipeline/AppCoordinator.swift`, find:

```swift
    private var machine = RecorderStateMachine()
    private var session: RecordingSession?
```

(currently at lines 51-52) and change it to:

```swift
    private var machine = RecorderStateMachine()
    private var session: RecordingSession?
    private var pendingConversion: PendingConversion?

    private struct PendingConversion {
        let folderName: String
        let task: Task<Void, Error>
    }
```

- [ ] **Step 2: Rewrite `stopRecording()` to refresh immediately and dispatch conversion off-main**

In `audio-pipeline/AppCoordinator.swift`, replace this method (currently lines 126-143):

```swift
    func stopRecording() async {
        guard machine.stop() == .stopSession, let active = session else { return }

        let folder = active.folder
        let result = active.stop()
        session = nil

        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")

        let stoppedAction = machine.sessionStopped(folderURL: folder.url)
        if case .convertOutput = stoppedAction {
            Task { @MainActor in
                let conversionResult = await self.runCombinedExport(for: folder)
                _ = self.machine.conversionFinished(conversionResult)
                self.library.refresh()
            }
        }
    }
```

with:

```swift
    func stopRecording() async {
        guard machine.stop() == .stopSession, let active = session else { return }

        let folder = active.folder
        let result = active.stop()
        session = nil

        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")

        let stoppedAction = machine.sessionStopped(folderURL: folder.url)
        guard case .convertOutput = stoppedAction else { return }

        // meta.json was written synchronously inside active.stop(); the row is
        // now visible to library.refresh().
        library.refresh()
        recordingActivity = "Converting recording…"

        let keepCAF = settings.keepOriginalCAF
        let conversionTask: Task<Void, Error> = Task.detached(priority: .utility) {
            let micURL = folder.micURL
            let systemURL = FileManager.default.fileExists(atPath: folder.systemURL.path)
                ? folder.systemURL : nil
            try await CombinedFLACExporter.combine(
                mic: micURL,
                system: systemURL,
                to: folder.combinedURL
            )
            if !keepCAF {
                try? FileManager.default.removeItem(at: micURL)
                if let systemURL { try? FileManager.default.removeItem(at: systemURL) }
            }
        }
        pendingConversion = PendingConversion(folderName: folder.name, task: conversionTask)

        Task { @MainActor in
            let conversionResult: Result<Void, Error>
            do {
                try await conversionTask.value
                conversionResult = .success(())
            } catch {
                Self.log.error("combined export failed: \(String(describing: error), privacy: .public)")
                conversionResult = .failure(error)
            }
            _ = self.machine.conversionFinished(conversionResult)
            self.library.refresh()
            self.pendingConversion = nil
            switch conversionResult {
            case .success:
                await self.flashRecordingActivity("Recording ready")
            case .failure(let error):
                await self.flashRecordingActivity("Conversion failed: \(error.localizedDescription)")
            }
        }
    }
```

- [ ] **Step 3: Delete the now-unused `runCombinedExport` method**

In `audio-pipeline/AppCoordinator.swift`, remove this method (currently lines 145-165):

```swift
    // Runs after a recording stops. Mixes mic+system into a single combined.flac;
    // optionally deletes the source .caf files per the user's setting.
    private func runCombinedExport(for folder: RecordingFolder) async -> Result<Void, Error> {
        let mic = folder.micURL
        let system = FileManager.default.fileExists(atPath: folder.systemURL.path)
            ? folder.systemURL : nil
        let dest = folder.combinedURL

        do {
            try await CombinedFLACExporter.combine(mic: mic, system: system, to: dest)
        } catch {
            Self.log.error("combined export failed: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }

        if !settings.keepOriginalCAF {
            try? FileManager.default.removeItem(at: folder.micURL)
            if let system { try? FileManager.default.removeItem(at: system) }
        }
        return .success(())
    }
```

- [ ] **Step 4: Verify the app target compiles**

Run: `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(coordinator): off-main recording conversion + immediate row

Runs CombinedFLACExporter on a detached .utility-priority task so the UI no
longer freezes during conversion. Refreshes the library immediately at stop
(meta.json is now sync-written) so the new row appears before conversion
completes. Tracks the in-flight task in pendingConversion so runJob can wait
on it.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `runJob` waits on an in-flight conversion for the same recording

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Add the pending-conversion wait at the top of `runJob(_:on:)`**

In `audio-pipeline/AppCoordinator.swift`, find the current method (lines 181-203):

```swift
    @discardableResult
    func runJob(_ job: Job, on recordingFolder: URL) async -> Result<URL, Error> {
        let recordingName = recordingFolder.lastPathComponent
        jobActivity = "Running '\(job.name)' on '\(recordingName)'…"

        // combined.flac is the canonical input — guaranteed to exist after a
        // successful recording (mic + optional system mixed at stop).
        let target = recordingFolder.appendingPathComponent("combined.flac")
        guard FileManager.default.fileExists(atPath: target.path) else {
            await self.flashActivity("Failed: '\(job.name)' — combined.flac missing")
            return .failure(JobRunError.combinedFlacMissing)
        }
        ...
```

and change the prologue to:

```swift
    @discardableResult
    func runJob(_ job: Job, on recordingFolder: URL) async -> Result<URL, Error> {
        let recordingName = recordingFolder.lastPathComponent

        // If conversion for this recording is still in flight, wait for it
        // before checking combined.flac. Failure is fine here — the existence
        // check below will return the canonical .combinedFlacMissing.
        if let pending = pendingConversion, pending.folderName == recordingName {
            jobActivity = "Waiting for '\(recordingName)' to finish converting…"
            _ = try? await pending.task.value
        }

        jobActivity = "Running '\(job.name)' on '\(recordingName)'…"

        // combined.flac is the canonical input — guaranteed to exist after a
        // successful recording (mic + optional system mixed at stop).
        let target = recordingFolder.appendingPathComponent("combined.flac")
        guard FileManager.default.fileExists(atPath: target.path) else {
            await self.flashActivity("Failed: '\(job.name)' — combined.flac missing")
            return .failure(JobRunError.combinedFlacMissing)
        }
```

(Leave the rest of `runJob` unchanged.)

- [ ] **Step 2: Verify the app target compiles**

Run: `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(jobs): wait for in-flight conversion before running a job

If runJob is triggered against a recording whose CAF→FLAC conversion is still
running, await the pendingConversion task first so the existing combined.flac
existence check passes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Second status footer in `RecordingsView`

**Files:**
- Modify: `audio-pipeline/UI/RecordingsView.swift`

- [ ] **Step 1: Add a small `StatusFooterRow` subview at the bottom of the file**

In `audio-pipeline/UI/RecordingsView.swift`, immediately after the closing `}` of `struct RecordingsView` (currently line 114), add:

```swift
private struct StatusFooterRow: View {
    let text: String

    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
```

- [ ] **Step 2: Replace the existing inline footer block with two `StatusFooterRow` instances**

In `audio-pipeline/UI/RecordingsView.swift`, replace this block (currently lines 73-88):

```swift
            if let activity = coordinator.jobActivity {
                Divider()
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
```

with:

```swift
            // Recording-conversion footer is closer-in-time to a stop, so it
            // renders above the job footer when both are visible.
            if let activity = coordinator.recordingActivity {
                Divider()
                StatusFooterRow(text: activity)
            }
            if let activity = coordinator.jobActivity {
                Divider()
                StatusFooterRow(text: activity)
            }
```

- [ ] **Step 3: Extend the animation modifier so it tracks `recordingActivity` too**

In `audio-pipeline/UI/RecordingsView.swift`, find:

```swift
        .animation(.easeInOut(duration: 0.18), value: coordinator.jobActivity)
```

(currently line 91) and change it to:

```swift
        .animation(.easeInOut(duration: 0.18), value: coordinator.jobActivity)
        .animation(.easeInOut(duration: 0.18), value: coordinator.recordingActivity)
```

- [ ] **Step 4: Verify the app target compiles**

Run: `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/UI/RecordingsView.swift
git commit -m "$(cat <<'EOF'
feat(recordings): footer status for in-flight recording conversion

Extracts the existing job-activity footer into a StatusFooterRow subview and
renders a second instance bound to recordingActivity. Conversion row sits
above the job row when both are visible.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Manual end-to-end verification

**Files:** none (manual)

These cases collectively cover the spec's success criteria. Use the `xcode-build` skill's helper to build, then launch the app from the built product.

- [ ] **Step 1: Build the app for Debug and locate the bundle**

Run: `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -showBuildSettings | rg '^\s+BUILT_PRODUCTS_DIR'`
Expected: a line like `BUILT_PRODUCTS_DIR = /Users/miklos/.../Build/Products/Debug`.

- [ ] **Step 2: Launch the app**

Run: `open "<BUILT_PRODUCTS_DIR>/audio-pipeline.app"`
(Use the path from Step 1.)

- [ ] **Step 3: Verify the immediate row + responsive UI scenario**

  1. Open the Recordings panel from the menu bar.
  2. Start a recording from the menu bar; speak / play audio for ~5 seconds.
  3. Stop the recording.
  4. **Expect:** the new row appears in the Recordings panel within a frame, the bottom footer shows `Converting recording…` with a spinner, and the table/window remain interactive while conversion runs.
  5. **Expect:** after conversion completes, the footer flashes `Recording ready` for ~3 s and then disappears; the row's Format column shows the FLAC summary.

- [ ] **Step 4: Verify Run-Job-while-converting**

  1. Define a Job (Settings → Jobs) if none exists.
  2. Start a recording, speak briefly, stop.
  3. Immediately right-click the new (still-converting) row → Run Job → pick the job.
  4. **Expect:** the bottom footer shows `Waiting for '<name>' to finish converting…`, then transitions to `Running '<job>' on '<name>'…`, then to `Done: …` (the existing job footer text). No `combined.flac missing` failure.

- [ ] **Step 5: Verify parallel footers**

  1. Start recording A, stop it.
  2. While A is converting, right-click a previously-completed recording B → Run Job.
  3. **Expect:** both footers visible simultaneously — `Converting recording…` on top, `Running '<job>' on 'B'…` below.

- [ ] **Step 6: Verify conversion failure path (optional)**

  Easiest reproducer: pre-test, set `keepOriginalCAF = false` (Settings). Start a recording, stop it, immediately delete `mic.caf` from the new recording folder via Finder before conversion reads it.
  **Expect:** footer flashes `Conversion failed: …`; the row stays visible with the CAF format summary.

- [ ] **Step 7: If all checks pass, push**

```bash
git push origin <current-branch>
```

(If working on `main` directly, push `main`. Otherwise push the feature branch; merging is out of scope for this plan.)

---

## Self-review notes

- **Spec coverage:**
  - Immediate row appearance — Task 1 (sync meta.json) + Task 4 (refresh at stop). ✓
  - Footer progress — Task 3 (state) + Task 6 (UI). ✓
  - Off-main + lower priority — Task 4 (`Task.detached(priority: .utility)`). ✓
  - Run Job waits on in-flight conversion — Task 5. ✓
  - Synchronous `meta.json` write — Task 1. ✓
  - Parallel footers — Task 6. ✓
  - Misleading comment fix — Task 2. ✓
- **Spec deviation:** the spec called for an SPM test on `RecordingSession.stop()` synchronous write; not feasible without an audio device. Documented under "Test surface note" above.
- **Type consistency:** `PendingConversion.folderName` / `.task` used identically in Tasks 4 and 5; `recordingActivity` / `flashRecordingActivity` used identically in Tasks 3, 4, and 6.
- **No placeholders:** every code change shows the full before/after; commit messages and verification commands are concrete.
