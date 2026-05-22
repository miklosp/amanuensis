# Test Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add exhaustive automated tests for every deterministic part of the app, and refactor the recording lifecycle into a pure, fully testable state machine so its decision logic is covered too.

**Architecture:** Approach C from the spec — extract `RecorderStateMachine` (pure value type), `OutputConversionPlanner`, and `RecordingFormatters`; `AppCoordinator` becomes a thin driver that only executes effects. Tests target the pure types plus file/audio integration units. Core Audio / `AVAudioEngine` / TCC primitives stay manual (spec §6).

**Tech Stack:** Swift 5.0, macOS 26.3, Swift Testing (`import Testing`), AVFoundation, the `xcodeproj` Ruby gem for test-target creation.

**Spec:** `docs/superpowers/specs/2026-05-22-test-coverage-design.md`

---

## Conventions

All work happens on the existing `test-coverage` branch.

**Build the app** (verifying a refactor compiles):

```bash
xcodebuild build \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -configuration Debug \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox
```

**Run a test suite:**

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/<SuiteName>
```

Replace `<SuiteName>` with the suite under test, or drop `-only-testing:` to run the whole bundle.

Why these flags (from project memory): DerivedData **must** live in `/tmp` — the repo is inside iCloud-synced `~/Documents`, and a build inside that tree fails codesign. `OTHER_SWIFT_FLAGS=-disable-sandbox` is **mandatory** for any build using Swift macros (`@Observable`, and the `@Test`/`#expect` macros) — the compiler's macro-plugin sandbox cannot nest inside Claude Code's sandbox. These commands may equivalently be run through the `xcodebuildmcp-cli` skill.

**Adding test files to the target:** the `audio-pipelineTests` target is not a synchronized group, so every new test file must be registered. Each task that adds a test file runs `bash scripts/run-setup-tests.sh`, which is idempotent — it installs the `xcodeproj` gem if missing, then syncs all `.swift` files under `audio-pipelineTests/` into the target. This modifies `audio-pipeline.xcodeproj/project.pbxproj`, which is committed with each task.

---

## Task 1: Scaffold the test target

Creates the `xcodeproj` tooling scripts, the `audio-pipelineTests` Swift Testing target, a shared scheme, and a smoke test proving the whole pipeline works.

**Files:**
- Create: `scripts/setup-tests.rb`
- Create: `scripts/run-setup-tests.sh`
- Create: `audio-pipelineTests/SmokeTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`
- Create (by script): `audio-pipeline.xcodeproj/xcshareddata/xcschemes/audio-pipeline.xcscheme`

- [ ] **Step 1: Write the xcodeproj script**

Create `scripts/setup-tests.rb`:

```ruby
#!/usr/bin/env ruby
# Idempotently ensures the `audio-pipelineTests` Swift Testing unit-test target
# exists and that every .swift file under audio-pipelineTests/ belongs to it.
# Also writes a shared `audio-pipeline` scheme whose Test action runs the suite.
#
# Run from the repo root, via scripts/run-setup-tests.sh.

require 'xcodeproj'

PROJECT_PATH = 'audio-pipeline.xcodeproj'
APP_TARGET   = 'audio-pipeline'
TEST_TARGET  = 'audio-pipelineTests'
TEST_DIR     = 'audio-pipelineTests'

project = Xcodeproj::Project.open(PROJECT_PATH)

app = project.targets.find { |t| t.name == APP_TARGET }
raise "app target '#{APP_TARGET}' not found" unless app

app_debug  = app.build_configurations.find { |c| c.name == 'Debug' }
deployment = app_debug.build_settings['MACOSX_DEPLOYMENT_TARGET'] || '26.3'
swift_ver  = app_debug.build_settings['SWIFT_VERSION'] || '5.0'

# @testable import requires the app module to be built testable in Debug.
app.build_configurations.each do |config|
  config.build_settings['ENABLE_TESTABILITY'] ||= 'YES'
end

test_target = project.targets.find { |t| t.name == TEST_TARGET }

if test_target.nil?
  test_target = project.new_target(:unit_test_bundle, TEST_TARGET, :osx, deployment, nil, :swift)
  test_target.add_dependency(app)

  test_target.build_configurations.each do |config|
    s = config.build_settings
    s['PRODUCT_BUNDLE_IDENTIFIER']     = 'work.miklos.audio-pipeline.tests'
    s['PRODUCT_NAME']                  = '$(TARGET_NAME)'
    s['SWIFT_VERSION']                 = swift_ver
    s['SWIFT_DEFAULT_ACTOR_ISOLATION'] = 'MainActor'
    s['MACOSX_DEPLOYMENT_TARGET']      = deployment
    s['GENERATE_INFOPLIST_FILE']       = 'YES'
    s['TEST_HOST']     = '$(BUILT_PRODUCTS_DIR)/audio-pipeline.app/Contents/MacOS/audio-pipeline'
    s['BUNDLE_LOADER'] = '$(TEST_HOST)'
    s['CODE_SIGN_STYLE'] = 'Automatic'
  end
  puts "created target #{TEST_TARGET}"
else
  puts "target #{TEST_TARGET} already exists"
end

# --- sync test source files into the target ---------------------------------
group = project.main_group.find_subpath(TEST_DIR, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(TEST_DIR)

phase    = test_target.source_build_phase
existing = phase.files_references.compact.map { |r| r.real_path.to_s }

Dir.glob("#{TEST_DIR}/**/*.swift").sort.each do |rel_path|
  abs = File.expand_path(rel_path)
  next if existing.include?(abs)
  ref = project.reference_for_path(abs) || group.new_file(abs)
  phase.add_file_reference(ref, true)
  puts "added #{rel_path}"
end

# --- shared scheme ----------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(test_target)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, APP_TARGET, true)
puts "wrote shared scheme #{APP_TARGET}"

project.save
puts "saved #{PROJECT_PATH}"
```

- [ ] **Step 2: Write the wrapper script**

Create `scripts/run-setup-tests.sh`:

```bash
#!/usr/bin/env bash
# Installs the xcodeproj gem (once, into /tmp) and runs setup-tests.rb.
# Run from the repo root.
set -euo pipefail

GEM_DIR=/tmp/audio-pipeline-gems

if ! GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby -e 'require "xcodeproj"' 2>/dev/null; then
  echo "installing xcodeproj into $GEM_DIR …"
  # If this fails citing the Ruby version, append a pin, e.g. -v 1.25.0
  gem install --install-dir "$GEM_DIR" --no-document xcodeproj
fi

GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby scripts/setup-tests.rb
```

- [ ] **Step 3: Write the smoke test**

Create `audio-pipelineTests/SmokeTests.swift`:

```swift
import Testing
@testable import audio_pipeline

@Suite struct SmokeTests {
    @Test func testTargetIsWiredToTheAppModule() {
        // References an app type — proves @testable import links.
        #expect(AppSettings.OutputFormat.allCases.count == 3)
    }
}
```

- [ ] **Step 4: Create the target and run the smoke test**

Run: `bash scripts/run-setup-tests.sh`
Expected: prints `created target audio-pipelineTests`, `added audio-pipelineTests/SmokeTests.swift`, `wrote shared scheme audio-pipeline`, `saved audio-pipeline.xcodeproj`.

Then run:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/SmokeTests
```

Expected: `TEST SUCCEEDED`, one test passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-tests.rb scripts/run-setup-tests.sh \
        audio-pipelineTests/SmokeTests.swift \
        audio-pipeline.xcodeproj/project.pbxproj \
        audio-pipeline.xcodeproj/xcshareddata/xcschemes/audio-pipeline.xcscheme
git commit -m "test: scaffold audio-pipelineTests Swift Testing target"
```

---

## Task 2: Add Equatable conformances

The extracted state machine and the metadata tests need value-equality. Pure conformance change, no behaviour impact.

**Files:**
- Modify: `audio-pipeline/Storage/RecordingStore.swift` (the `RecordingFolder` struct)
- Modify: `audio-pipeline/Storage/RecordingMetadata.swift`

- [ ] **Step 1: Make `RecordingFolder` Equatable**

In `audio-pipeline/Storage/RecordingStore.swift`, change the struct declaration:

```swift
struct RecordingFolder: Sendable, Equatable {
```

(All stored properties — `url: URL`, `name: String`, `startedAt: Date` — are already `Equatable`, so the conformance is synthesized.)

- [ ] **Step 2: Make `RecordingMetadata` and `TrackMetadata` Equatable**

In `audio-pipeline/Storage/RecordingMetadata.swift`, change both declarations:

```swift
struct RecordingMetadata: Codable, Sendable, Equatable {
```

```swift
    struct TrackMetadata: Codable, Sendable, Equatable {
```

- [ ] **Step 3: Verify the app still builds**

```bash
xcodebuild build \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -configuration Debug \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/Storage/RecordingStore.swift \
        audio-pipeline/Storage/RecordingMetadata.swift
git commit -m "refactor: add Equatable conformances for test support"
```

---

## Task 3: Test support helpers

Shared helpers used by the Storage- and Audio-layer test tasks.

**Files:**
- Create: `audio-pipelineTests/Support/TempDirectory.swift`
- Create: `audio-pipelineTests/Support/SyntheticAudio.swift`
- Create: `audio-pipelineTests/Support/Fixtures.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write `TempDirectory`**

Create `audio-pipelineTests/Support/TempDirectory.swift`:

```swift
import Foundation

/// A unique temporary directory. Create it in a test and call `cleanup()`
/// from a `defer` block:
///
///     let temp = TempDirectory()
///     defer { temp.cleanup() }
struct TempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "audio-pipeline-tests-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: Write `SyntheticAudio`**

Create `audio-pipelineTests/Support/SyntheticAudio.swift`:

```swift
import AVFoundation
import Foundation

/// Builds in-memory audio buffers and on-disk CAF fixtures for tests that
/// must not touch real capture hardware.
enum SyntheticAudio {

    /// A standard non-interleaved float format.
    static func format(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    /// A buffer of `frames` silent frames in the given format.
    static func buffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // standardFormat is float; a zero-filled buffer is silence.
        if let channels = buffer.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) {
                    channels[ch][frame] = 0
                }
            }
        }
        return buffer
    }

    /// Writes a CAF file of `frames` silent frames at the given URL.
    static func writeCAF(to url: URL,
                         sampleRate: Double,
                         channels: AVAudioChannelCount,
                         frames: AVAudioFrameCount) throws {
        let fmt = format(sampleRate: sampleRate, channels: channels)
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        if frames > 0 {
            try file.write(from: buffer(format: fmt, frames: frames))
        }
    }
}
```

- [ ] **Step 3: Write `Fixtures`**

Create `audio-pipelineTests/Support/Fixtures.swift`:

```swift
import Foundation
@testable import audio_pipeline

/// Builds `RecordingMetadata` values and on-disk recording folders for
/// Storage-layer tests.
enum Fixtures {

    static func metadata(folderName: String,
                         startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                         duration: Double? = 12.5) -> RecordingMetadata {
        RecordingMetadata(
            folderName: folderName,
            startedAt: startedAt,
            stoppedAt: duration.map { startedAt.addingTimeInterval($0) },
            durationSeconds: duration,
            mic: RecordingMetadata.TrackMetadata(
                fileName: "mic.caf", sampleRate: 48_000, channelCount: 1,
                formatID: "alac", framesWritten: 600_000),
            system: nil,
            hostAppVersion: "1.0",
            notes: nil
        )
    }

    /// Creates a recording folder containing `meta.json` plus the named track
    /// files (each filled with the given number of zero bytes). Returns the
    /// folder URL.
    @discardableResult
    static func recordingFolder(in parent: URL,
                                name: String,
                                metadata: RecordingMetadata? = nil,
                                trackFiles: [String: Int] = [:]) throws -> URL {
        let folder = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta = metadata ?? Self.metadata(folderName: name)
        try meta.write(to: folder.appending(path: "meta.json", directoryHint: .notDirectory))
        for (file, bytes) in trackFiles {
            try Data(count: bytes)
                .write(to: folder.appending(path: file, directoryHint: .notDirectory))
        }
        return folder
    }
}
```

- [ ] **Step 4: Register the files and verify the target still builds**

Run: `bash scripts/run-setup-tests.sh`
Expected: prints `added` lines for the three Support files.

Then run the smoke test (proves the helpers compile inside the target):

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/SmokeTests
```

Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add audio-pipelineTests/Support/ audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add temp-directory, synthetic-audio, and fixture helpers"
```

---

## Task 4: `RecorderStateMachine` + tests

The core of the refactor — a pure value-type state machine carrying all recording-lifecycle decision logic.

**Files:**
- Create: `audio-pipeline/Audio/RecorderStateMachine.swift`
- Create: `audio-pipelineTests/RecorderStateMachineTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `audio-pipelineTests/RecorderStateMachineTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct RecorderStateMachineTests {

    private func folder(_ name: String = "rec-1") -> RecordingFolder {
        RecordingFolder(
            url: URL(filePath: "/tmp/\(name)", directoryHint: .isDirectory),
            name: name,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private struct TestError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Drives a fresh machine to the `.recording` phase.
    private func recordingMachine(folder f: RecordingFolder) -> RecorderStateMachine {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        _ = m.folderCreated(.success(f))
        _ = m.sessionStarted(.success(()))
        return m
    }

    // MARK: start()

    @Test func startFromIdleEntersStarting() {
        var m = RecorderStateMachine()
        let action = m.start()
        #expect(action == .requestMicPermission)
        #expect(m.phase == .starting(folder: nil))
        #expect(m.isBusy)
    }

    @Test func startClearsStaleError() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: false)
        #expect(m.lastError != nil)
        _ = m.start()
        #expect(m.lastError == nil)
    }

    @Test func startIsIgnoredWhileRecording() {
        var m = recordingMachine(folder: folder())
        let before = m.phase
        let action = m.start()
        #expect(action == .ignore)
        #expect(m.phase == before)
    }

    // MARK: mic permission

    @Test func micGrantedRequestsSystemPermission() {
        var m = RecorderStateMachine()
        _ = m.start()
        let action = m.micPermissionResolved(granted: true)
        #expect(action == .requestSystemPermission)
        #expect(m.phase == .starting(folder: nil))
    }

    @Test func micDeniedReturnsToIdleWithError() {
        var m = RecorderStateMachine()
        _ = m.start()
        let action = m.micPermissionResolved(granted: false)
        #expect(action == .none)
        #expect(m.phase == .idle)
        #expect(m.lastError == RecorderStateMachine.micDeniedMessage)
    }

    // MARK: system permission

    @Test func systemPermissionResolvedRequestsFolder() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        let action = m.systemPermissionResolved()
        #expect(action == .createFolder)
        #expect(m.phase == .starting(folder: nil))
    }

    // MARK: folder creation

    @Test func folderCreatedSuccessStartsSession() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        let f = folder()
        let action = m.folderCreated(.success(f))
        #expect(action == .startSession(f))
        #expect(m.phase == .starting(folder: f))
    }

    @Test func folderCreatedFailureReturnsToIdleWithError() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        let action = m.folderCreated(.failure(TestError(message: "disk full")))
        #expect(action == .none)
        #expect(m.phase == .idle)
        #expect(m.lastError == "Couldn't create recording folder: disk full")
    }

    // MARK: session start

    @Test func sessionStartedSuccessEntersRecording() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        let f = folder()
        _ = m.folderCreated(.success(f))
        let action = m.sessionStarted(.success(()))
        #expect(action == .none)
        #expect(m.phase == .recording(folder: f))
        #expect(m.isRecording)
    }

    @Test func sessionStartedFailureReturnsToIdleWithError() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        _ = m.folderCreated(.success(folder()))
        let action = m.sessionStarted(.failure(TestError(message: "no device")))
        #expect(action == .none)
        #expect(m.phase == .idle)
        #expect(m.lastError == "Couldn't start recording: no device")
    }

    // MARK: stop

    @Test func stopFromRecordingEntersStopping() {
        let f = folder()
        var m = recordingMachine(folder: f)
        let action = m.stop()
        #expect(action == .stopSession)
        #expect(m.phase == .stopping(folder: f))
        #expect(m.isBusy)
    }

    @Test func sessionStoppedReturnsToIdleAndConverts() {
        let f = folder()
        var m = recordingMachine(folder: f)
        _ = m.stop()
        let action = m.sessionStopped()
        #expect(action == .convertOutput(f))
        #expect(m.phase == .idle)
        #expect(m.lastFolderURL == f.url)
    }

    // MARK: conversion

    @Test func conversionSuccessRefreshesLibrary() {
        var m = recordingMachine(folder: folder())
        _ = m.stop()
        _ = m.sessionStopped()
        let action = m.conversionFinished(.success(()))
        #expect(action == .refreshLibrary)
        #expect(m.lastError == nil)
    }

    @Test func conversionFailureSetsErrorAndRefreshes() {
        var m = recordingMachine(folder: folder())
        _ = m.stop()
        _ = m.sessionStopped()
        let action = m.conversionFinished(.failure(TestError(message: "bad codec")))
        #expect(action == .refreshLibrary)
        #expect(m.lastError == "FLAC conversion failed: bad codec")
    }

    // MARK: out-of-phase events are ignored

    @Test func stopIsIgnoredWhenIdle() {
        var m = RecorderStateMachine()
        let action = m.stop()
        #expect(action == .ignore)
        #expect(m.phase == .idle)
    }

    @Test func micPermissionIsIgnoredWhenIdle() {
        var m = RecorderStateMachine()
        let action = m.micPermissionResolved(granted: true)
        #expect(action == .ignore)
        #expect(m.phase == .idle)
    }

    @Test func sessionStartedIsIgnoredBeforeFolderCreated() {
        var m = RecorderStateMachine()
        _ = m.start()
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        // phase is .starting(folder: nil) — no folder yet
        let action = m.sessionStarted(.success(()))
        #expect(action == .ignore)
        #expect(m.phase == .starting(folder: nil))
    }

    @Test func sessionStoppedIsIgnoredWhenNotStopping() {
        var m = recordingMachine(folder: folder())
        let action = m.sessionStopped()
        #expect(action == .ignore)
        #expect(m.isRecording)
    }

    // MARK: queries

    @Test func statusTextPerPhase() {
        var m = RecorderStateMachine()
        #expect(m.statusText == "Idle")
        _ = m.start()
        #expect(m.statusText == "Starting…")
        _ = m.micPermissionResolved(granted: true)
        _ = m.systemPermissionResolved()
        let f = folder("session-x")
        _ = m.folderCreated(.success(f))
        _ = m.sessionStarted(.success(()))
        #expect(m.statusText == "Recording: session-x")
        _ = m.stop()
        #expect(m.statusText == "Stopping…")
    }

    @Test func happyPathActionSequence() {
        var m = RecorderStateMachine()
        let f = folder()
        #expect(m.start() == .requestMicPermission)
        #expect(m.micPermissionResolved(granted: true) == .requestSystemPermission)
        #expect(m.systemPermissionResolved() == .createFolder)
        #expect(m.folderCreated(.success(f)) == .startSession(f))
        #expect(m.sessionStarted(.success(())) == .none)
        #expect(m.stop() == .stopSession)
        #expect(m.sessionStopped() == .convertOutput(f))
        #expect(m.conversionFinished(.success(())) == .refreshLibrary)
        #expect(m.phase == .idle)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash scripts/run-setup-tests.sh` (registers the new test file), then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecorderStateMachineTests
```

Expected: build failure — `cannot find 'RecorderStateMachine' in scope`.

- [ ] **Step 3: Write the state machine**

Create `audio-pipeline/Audio/RecorderStateMachine.swift`:

```swift
import Foundation

// The recording lifecycle as a pure value type. Transition methods mutate
// state and return a typed `Action`; the driver (`AppCoordinator`) executes
// the action's side effect and feeds the result back as the next event.
// Out-of-phase events return `.ignore` and change nothing.
struct RecorderStateMachine {

    enum Phase: Equatable {
        case idle
        case starting(folder: RecordingFolder?)   // folder is nil until created
        case recording(folder: RecordingFolder)
        case stopping(folder: RecordingFolder)
    }

    enum Action: Equatable {
        case requestMicPermission
        case requestSystemPermission
        case createFolder
        case startSession(RecordingFolder)
        case stopSession
        case convertOutput(RecordingFolder)
        case refreshLibrary
        case none      // valid transition, no driver effect
        case ignore    // event not applicable in this phase; nothing changed
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var lastFolderURL: URL?

    static let micDeniedMessage =
        "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."

    // MARK: Events

    mutating func start() -> Action {
        guard case .idle = phase else { return .ignore }
        phase = .starting(folder: nil)
        lastError = nil
        return .requestMicPermission
    }

    mutating func micPermissionResolved(granted: Bool) -> Action {
        guard case .starting = phase else { return .ignore }
        if granted { return .requestSystemPermission }
        phase = .idle
        lastError = Self.micDeniedMessage
        return .none
    }

    mutating func systemPermissionResolved() -> Action {
        guard case .starting = phase else { return .ignore }
        return .createFolder
    }

    mutating func folderCreated(_ result: Result<RecordingFolder, Error>) -> Action {
        guard case .starting = phase else { return .ignore }
        switch result {
        case .success(let folder):
            phase = .starting(folder: folder)
            return .startSession(folder)
        case .failure(let error):
            phase = .idle
            lastError = "Couldn't create recording folder: \(error.localizedDescription)"
            return .none
        }
    }

    mutating func sessionStarted(_ result: Result<Void, Error>) -> Action {
        guard case .starting(let folder?) = phase else { return .ignore }
        switch result {
        case .success:
            phase = .recording(folder: folder)
            return .none
        case .failure(let error):
            phase = .idle
            lastError = "Couldn't start recording: \(error.localizedDescription)"
            return .none
        }
    }

    mutating func stop() -> Action {
        guard case .recording(let folder) = phase else { return .ignore }
        phase = .stopping(folder: folder)
        return .stopSession
    }

    mutating func sessionStopped() -> Action {
        guard case .stopping(let folder) = phase else { return .ignore }
        lastFolderURL = folder.url
        phase = .idle
        return .convertOutput(folder)
    }

    mutating func conversionFinished(_ result: Result<Void, Error>) -> Action {
        if case .failure(let error) = result {
            lastError = "FLAC conversion failed: \(error.localizedDescription)"
        }
        return .refreshLibrary
    }

    // MARK: Queries

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .starting, .stopping: return true
        case .idle, .recording:    return false
        }
    }

    var statusText: String {
        switch phase {
        case .idle:                  return "Idle"
        case .starting:              return "Starting…"
        case .recording(let folder): return "Recording: \(folder.name)"
        case .stopping:              return "Stopping…"
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecorderStateMachineTests
```

Expected: `TEST SUCCEEDED`, 20 tests passed.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/Audio/RecorderStateMachine.swift \
        audio-pipelineTests/RecorderStateMachineTests.swift \
        audio-pipeline.xcodeproj/project.pbxproj
git commit -m "feat: add RecorderStateMachine with exhaustive transition tests"
```

---

## Task 5: `OutputConversionPlanner` + tests

Pure helper for the post-recording FLAC-conversion decision tree.

**Files:**
- Create: `audio-pipeline/Audio/OutputConversionPlanner.swift`
- Create: `audio-pipelineTests/OutputConversionPlannerTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `audio-pipelineTests/OutputConversionPlannerTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct OutputConversionPlannerTests {

    private func folder() -> RecordingFolder {
        RecordingFolder(
            url: URL(filePath: "/tmp/rec", directoryHint: .isDirectory),
            name: "rec",
            startedAt: Date()
        )
    }

    @Test func cafFormatProducesNoTasks() {
        #expect(OutputConversionPlanner.plan(format: .caf, folder: folder()).isEmpty)
    }

    @Test func flacFormatConvertsBothTracksAndDeletesSources() {
        let f = folder()
        let tasks = OutputConversionPlanner.plan(format: .flac, folder: f)
        #expect(tasks.count == 2)
        #expect(tasks[0].source == f.micURL)
        #expect(tasks[0].destination ==
                f.url.appending(path: "mic.flac", directoryHint: .notDirectory))
        #expect(tasks[1].source == f.systemURL)
        #expect(tasks[1].destination ==
                f.url.appending(path: "system.flac", directoryHint: .notDirectory))
        #expect(tasks.allSatisfy { $0.deleteSourceAfterExport })
    }

    @Test func bothFormatConvertsBothTracksAndKeepsSources() {
        let tasks = OutputConversionPlanner.plan(format: .both, folder: folder())
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { !$0.deleteSourceAfterExport })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/OutputConversionPlannerTests
```

Expected: build failure — `cannot find 'OutputConversionPlanner' in scope`.

- [ ] **Step 3: Write the planner**

Create `audio-pipeline/Audio/OutputConversionPlanner.swift`:

```swift
import Foundation

// One CAF track queued for FLAC conversion.
struct ConversionTask: Equatable {
    let source: URL              // the .caf to convert
    let destination: URL         // the .flac to write
    let deleteSourceAfterExport: Bool
}

// Pure planner for the post-recording output conversion. Decides which tracks
// to convert and whether the source .caf should be removed afterwards. The
// file-exists check and the actual export run in the driver.
enum OutputConversionPlanner {
    static func plan(format: AppSettings.OutputFormat,
                     folder: RecordingFolder) -> [ConversionTask] {
        guard format != .caf else { return [] }
        let deleteSource = (format == .flac)
        return [
            ConversionTask(
                source: folder.micURL,
                destination: folder.url.appending(path: "mic.flac",
                                                  directoryHint: .notDirectory),
                deleteSourceAfterExport: deleteSource
            ),
            ConversionTask(
                source: folder.systemURL,
                destination: folder.url.appending(path: "system.flac",
                                                  directoryHint: .notDirectory),
                deleteSourceAfterExport: deleteSource
            ),
        ]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/OutputConversionPlannerTests
```

Expected: `TEST SUCCEEDED`, 3 tests passed.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/Audio/OutputConversionPlanner.swift \
        audio-pipelineTests/OutputConversionPlannerTests.swift \
        audio-pipeline.xcodeproj/project.pbxproj
git commit -m "feat: add OutputConversionPlanner with tests"
```

---

## Task 6: `RecordingFormatters` + tests, rewire `RecordingsView`

Lift the duration/size formatters out of the SwiftUI view into a testable type.

**Files:**
- Create: `audio-pipeline/UI/RecordingFormatters.swift`
- Create: `audio-pipelineTests/RecordingFormattersTests.swift`
- Modify: `audio-pipeline/UI/RecordingsView.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `audio-pipelineTests/RecordingFormattersTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct RecordingFormattersTests {

    @Test func durationTextNilIsDash() {
        #expect(RecordingFormatters.durationText(nil) == "—")
    }

    @Test(arguments: [
        (0.0, "0:00"),
        (5.0, "0:05"),
        (65.0, "1:05"),
        (90.5, "1:31"),
        (599.4, "9:59"),
    ])
    func durationTextFormatsMinutesAndSeconds(seconds: Double, expected: String) {
        #expect(RecordingFormatters.durationText(seconds) == expected)
    }

    @Test func sizeTextDelegatesToByteCountFormatter() {
        #expect(RecordingFormatters.sizeText(0)
                == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        #expect(RecordingFormatters.sizeText(1_500_000)
                == ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecordingFormattersTests
```

Expected: build failure — `cannot find 'RecordingFormatters' in scope`.

- [ ] **Step 3: Write `RecordingFormatters`**

Create `audio-pipeline/UI/RecordingFormatters.swift`:

```swift
import Foundation

// Display formatters for the Recordings window.
enum RecordingFormatters {
    static func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
```

- [ ] **Step 4: Rewire `RecordingsView`**

In `audio-pipeline/UI/RecordingsView.swift`, change the two table columns to call the new type:

```swift
            TableColumn("Duration") { Text(RecordingFormatters.durationText($0.duration)) }
            TableColumn("Size") { Text(RecordingFormatters.sizeText($0.sizeBytes)) }
```

Then delete the now-unused private helpers at the bottom of the file:

```swift
    private static func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
```

- [ ] **Step 5: Run the tests and build to verify**

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecordingFormattersTests
```

Expected: `TEST SUCCEEDED`, 7 tests passed (1 + 5 parameterized + 1). The build also compiles `RecordingsView` with the rewired calls.

- [ ] **Step 6: Commit**

```bash
git add audio-pipeline/UI/RecordingFormatters.swift \
        audio-pipeline/UI/RecordingsView.swift \
        audio-pipelineTests/RecordingFormattersTests.swift \
        audio-pipeline.xcodeproj/project.pbxproj
git commit -m "refactor: extract RecordingFormatters from RecordingsView with tests"
```

---

## Task 7: `AppCoordinator` driver refactor

Rewire `AppCoordinator` to drive `RecorderStateMachine`, and update `MenuBarContent`. This is the integration step. The driver's effect code touches Core Audio and is untested by design (spec §4 D4, §6) — verification is a successful build plus the full automated suite still passing.

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift` (full rewrite)
- Modify: `audio-pipeline/UI/MenuBarContent.swift`

- [ ] **Step 1: Rewrite `AppCoordinator`**

Replace the entire contents of `audio-pipeline/AppCoordinator.swift` with:

```swift
import AppKit
import Foundation
import Observation
import os

// Top-level app state. Drives `RecorderStateMachine`: each transition returns
// an `Action`, this type executes the action's side effect and feeds the
// result back as the next event. All lifecycle decision logic lives in the
// state machine — this is a thin, effect-only driver.
@MainActor
@Observable
final class AppCoordinator {
    private(set) var machine = RecorderStateMachine()

    let settings: AppSettings
    let library: RecordingsLibrary
    private var session: RecordingSession?

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = RecordingsLibrary(settings: settings)
    }

    var statusText: String { machine.statusText }
    var isRecording: Bool { machine.isRecording }
    var isBusy: Bool { machine.isBusy }
    var lastError: String? { machine.lastError }
    var lastFolderURL: URL? { machine.lastFolderURL }

    func toggleRecording() {
        Task { @MainActor in
            await run(machine.isRecording ? machine.stop() : machine.start())
        }
    }

    // Executes one action, feeds the resulting event back into the machine,
    // and recurses on the next action.
    private func run(_ action: RecorderStateMachine.Action) async {
        switch action {
        case .requestMicPermission:
            let granted = await MicRecorder.requestPermissionIfNeeded()
            await run(machine.micPermissionResolved(granted: granted))

        case .requestSystemPermission:
            // System audio capture is a separate TCC grant. A declined grant
            // still allows a mic-only recording — it only silences the system
            // track — so the machine does not branch on it.
            let granted = await AudioCapturePermission.requestIfNeeded()
            if !granted {
                Self.log.error("system audio capture not authorized — system track will be silent")
            }
            await run(machine.systemPermissionResolved())

        case .createFolder:
            let result = Result {
                try RecordingStore(baseURL: settings.recordingsDirectory)
                    .makeRecordingFolder(label: nil)
            }
            await run(machine.folderCreated(result))

        case .startSession(let folder):
            let result: Result<Void, Error>
            do {
                let newSession = try RecordingSession(folder: folder)
                try newSession.start()
                session = newSession
                Self.log.info("recording started in \(folder.name, privacy: .public)")
                result = .success(())
            } catch {
                Self.log.error("start failed: \(String(describing: error), privacy: .public)")
                result = .failure(error)
            }
            await run(machine.sessionStarted(result))

        case .stopSession:
            guard let active = session else { return }
            let stopResult = active.stop()
            session = nil
            Self.log.info("recording stopped — mic frames \(stopResult.mic.framesWritten, privacy: .public), system frames \(stopResult.system?.framesWritten ?? -1, privacy: .public)")
            await run(machine.sessionStopped())

        case .convertOutput(let folder):
            let result = await convertOutput(folder)
            await run(machine.conversionFinished(result))

        case .refreshLibrary:
            library.refresh()

        case .none, .ignore:
            break
        }
    }

    // Runs the conversion plan: exports each existing CAF track to FLAC and
    // removes the source when the plan says so. Returns the first failure, if
    // any, so the machine can surface it.
    private func convertOutput(_ folder: RecordingFolder) async -> Result<Void, Error> {
        let tasks = OutputConversionPlanner.plan(format: settings.outputFormat, folder: folder)
        var firstError: Error?
        for task in tasks {
            guard FileManager.default.fileExists(atPath: task.source.path) else { continue }
            do {
                try await FLACExporter.export(from: task.source, to: task.destination)
                if task.deleteSourceAfterExport {
                    try? FileManager.default.removeItem(at: task.source)
                }
            } catch {
                if firstError == nil { firstError = error }
                Self.log.error("FLAC export failed for \(task.source.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let firstError { return .failure(firstError) }
        return .success(())
    }

    func openRecordingsFolder() {
        RecordingStore(baseURL: settings.recordingsDirectory).revealInFinder()
    }

    func openLastRecordingFolder() {
        guard let url = machine.lastFolderURL else {
            openRecordingsFolder()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static let log = Logger(subsystem: "work.miklos.audio-pipeline", category: "coordinator")
}
```

- [ ] **Step 2: Update `MenuBarContent`**

In `audio-pipeline/UI/MenuBarContent.swift`, replace the `statusLine` reference in `body` with a direct `Text`, and delete the `statusLine` view builder.

Change the first line inside the `Group` from:

```swift
            statusLine
```

to:

```swift
            Text(coordinator.statusText)
```

Then delete the entire `statusLine` computed property at the end of the struct:

```swift
    @ViewBuilder private var statusLine: some View {
        switch coordinator.status {
        case .idle:
            Text("Idle")
        case .starting:
            Text("Starting…")
        case .recording(let name):
            Text("Recording: \(name)")
        case .stopping:
            Text("Stopping…")
        }
    }
```

- [ ] **Step 3: Build the app**

```bash
xcodebuild build \
  -project audio-pipeline.xcodeproj \
  -scheme audio-pipeline \
  -configuration Debug \
  -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox
```

Expected: `BUILD SUCCEEDED`. If the compiler reports an unused `startRecording`/`stopRecording` or a missing `AppCoordinator.Status` reference, ensure no other file still references them — `MenuBarContent` and `audio_pipelineApp.swift` should only use `toggleRecording()`, `statusText`, `isRecording`, `isBusy`, `lastError`, and `lastFolderURL`.

- [ ] **Step 4: Run the full test suite to confirm nothing regressed**

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests
```

Expected: `TEST SUCCEEDED` — all suites so far (Smoke, RecorderStateMachine, OutputConversionPlanner, RecordingFormatters) pass.

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift audio-pipeline/UI/MenuBarContent.swift
git commit -m "refactor: drive AppCoordinator through RecorderStateMachine"
```

---

## Task 8: `AppSettings` tests

Tests `UserDefaults`-backed preference persistence with an injected throwaway suite.

**Files:**
- Create: `audio-pipelineTests/AppSettingsTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/AppSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct AppSettingsTests {

    /// Runs `body` with a fresh, isolated UserDefaults suite, removed afterwards.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func firstRunUsesDefaults() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.recordingsDirectory == AppSettings.defaultRecordingsDirectory)
            #expect(settings.outputFormat == .caf)
        }
    }

    @Test func recordingsDirectoryPersists() {
        withDefaults { defaults in
            let custom = URL(filePath: "/tmp/custom-recordings", directoryHint: .isDirectory)
            AppSettings(defaults: defaults).recordingsDirectory = custom
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.recordingsDirectory.path(percentEncoded: false)
                    == custom.path(percentEncoded: false))
        }
    }

    @Test func outputFormatPersists() {
        withDefaults { defaults in
            AppSettings(defaults: defaults).outputFormat = .both
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.outputFormat == .both)
        }
    }

    @Test func invalidPersistedOutputFormatFallsBackToCAF() {
        withDefaults { defaults in
            defaults.set("nonsense", forKey: "outputFormat")
            #expect(AppSettings(defaults: defaults).outputFormat == .caf)
        }
    }

    @Test(arguments: AppSettings.OutputFormat.allCases)
    func outputFormatIdentifierMatchesRawValueAndHasTitle(_ format: AppSettings.OutputFormat) {
        #expect(format.id == format.rawValue)
        #expect(!format.title.isEmpty)
    }

    @Test func outputFormatCoversThreeCases() {
        #expect(Set(AppSettings.OutputFormat.allCases) == [.caf, .flac, .both])
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/AppSettingsTests
```

Expected: `TEST SUCCEEDED`, 8 tests passed (4 + 3 parameterized + 1). These test existing, correct code, so they pass on the first run.

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/AppSettingsTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add AppSettings persistence tests"
```

---

## Task 9: `RecordingStore` tests

Tests folder-name generation and folder creation in a temp directory.

**Files:**
- Create: `audio-pipelineTests/RecordingStoreTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/RecordingStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct RecordingStoreTests {

    @Test func folderNameIsISO8601WithColonsStripped() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let store = RecordingStore(baseURL: temp.url)
        let date = Date()
        let folder = try store.makeRecordingFolder(label: nil, date: date)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expected = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")

        #expect(folder.name == expected)
        #expect(!folder.name.contains(":"))
        #expect(FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func labelIsAppendedAndSanitised() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let store = RecordingStore(baseURL: temp.url)
        let folder = try store.makeRecordingFolder(label: "client/meeting", date: Date())
        #expect(folder.name.contains("_client-meeting"))
        #expect(!folder.name.contains("/"))
    }

    @Test func emptyLabelProducesNoSuffix() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let store = RecordingStore(baseURL: temp.url)
        let folder = try store.makeRecordingFolder(label: "", date: Date())
        #expect(!folder.name.contains("_"))
    }

    @Test func recordingFolderURLsResolveToExpectedNames() {
        let folder = RecordingFolder(
            url: URL(filePath: "/tmp/rec", directoryHint: .isDirectory),
            name: "rec",
            startedAt: Date()
        )
        #expect(folder.micURL.lastPathComponent == "mic.caf")
        #expect(folder.systemURL.lastPathComponent == "system.caf")
        #expect(folder.metadataURL.lastPathComponent == "meta.json")
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecordingStoreTests
```

Expected: `TEST SUCCEEDED`, 4 tests passed.

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/RecordingStoreTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add RecordingStore folder-naming tests"
```

---

## Task 10: `RecordingMetadata` tests

Tests Codable round-tripping and atomic file writing.

**Files:**
- Create: `audio-pipelineTests/RecordingMetadataTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/RecordingMetadataTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct RecordingMetadataTests {

    private func sample() -> RecordingMetadata {
        RecordingMetadata(
            folderName: "2026-05-22T09-30-00Z",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_700_000_042),
            durationSeconds: 42,
            mic: RecordingMetadata.TrackMetadata(
                fileName: "mic.caf", sampleRate: 48_000, channelCount: 1,
                formatID: "alac", framesWritten: 2_016_000),
            system: nil,
            hostAppVersion: "1.0",
            notes: "test"
        )
    }

    @Test func codableRoundTripPreservesAllFields() throws {
        let original = sample()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingMetadata.self, from: data)
        #expect(decoded == original)
    }

    @Test func schemaVersionDefaultsToOne() {
        #expect(sample().schemaVersion == 1)
    }

    @Test func writeThenReadRoundTrips() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = temp.url.appending(path: "meta.json", directoryHint: .notDirectory)
        let original = sample()
        try original.write(to: url)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingMetadata.self,
                                         from: Data(contentsOf: url))
        #expect(decoded == original)
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecordingMetadataTests
```

Expected: `TEST SUCCEEDED`, 3 tests passed.

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/RecordingMetadataTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add RecordingMetadata codable round-trip tests"
```

---

## Task 11: `RecordingItem` tests

Tests parsing of a recording folder into a `RecordingItem`.

**Files:**
- Create: `audio-pipelineTests/RecordingItemTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/RecordingItemTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct RecordingItemTests {

    @Test func parsesValidRecordingFolder() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let folder = try Fixtures.recordingFolder(
            in: temp.url, name: "rec-1",
            trackFiles: ["mic.caf": 1000, "system.caf": 2000])
        let item = try #require(RecordingItem(folderURL: folder))
        #expect(item.name == "rec-1")
        #expect(item.sizeBytes >= 3000)   // tracks + meta.json
    }

    @Test func missingMetadataYieldsNil() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let empty = temp.url.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(RecordingItem(folderURL: empty) == nil)
    }

    @Test func corruptMetadataYieldsNil() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let folder = temp.url.appending(path: "rec-bad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: folder.appending(path: "meta.json", directoryHint: .notDirectory))
        #expect(RecordingItem(folderURL: folder) == nil)
    }

    @Test(arguments: [
        (["mic.caf": 10], "caf"),
        (["mic.flac": 10], "flac"),
        (["mic.caf": 10, "system.flac": 10], "caf + flac"),
        ([:] as [String: Int], ""),
    ])
    func formatSummaryReflectsTrackFiles(files: [String: Int], expected: String) throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let folder = try Fixtures.recordingFolder(in: temp.url, name: "rec", trackFiles: files)
        let item = try #require(RecordingItem(folderURL: folder))
        #expect(item.formatSummary == expected)
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecordingItemTests
```

Expected: `TEST SUCCEEDED`, 7 tests passed (3 + 4 parameterized).

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/RecordingItemTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add RecordingItem parsing tests"
```

---

## Task 12: `RecordingsLibrary` tests

Tests directory scanning, sort order, and deletion.

**Files:**
- Create: `audio-pipelineTests/RecordingsLibraryTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/RecordingsLibraryTests.swift`:

```swift
import Testing
import Foundation
@testable import audio_pipeline

@Suite struct RecordingsLibraryTests {

    /// A library whose settings point at `directory`.
    private func library(at directory: URL) -> RecordingsLibrary {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.recordingsDirectory = directory
        return RecordingsLibrary(settings: settings)
    }

    @Test func refreshListsFoldersNewestFirst() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        try Fixtures.recordingFolder(
            in: temp.url, name: "older",
            metadata: Fixtures.metadata(folderName: "older",
                                        startedAt: Date(timeIntervalSince1970: 1_000)))
        try Fixtures.recordingFolder(
            in: temp.url, name: "newer",
            metadata: Fixtures.metadata(folderName: "newer",
                                        startedAt: Date(timeIntervalSince1970: 2_000)))

        let lib = library(at: temp.url)
        lib.refresh()
        #expect(lib.recordings.map(\.name) == ["newer", "older"])
    }

    @Test func refreshSkipsNonDirectoriesAndFoldersWithoutMetadata() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        try Fixtures.recordingFolder(in: temp.url, name: "valid")
        try Data().write(to: temp.url.appending(path: "stray.txt",
                                                directoryHint: .notDirectory))
        try FileManager.default.createDirectory(
            at: temp.url.appending(path: "no-meta", directoryHint: .isDirectory),
            withIntermediateDirectories: true)

        let lib = library(at: temp.url)
        lib.refresh()
        #expect(lib.recordings.map(\.name) == ["valid"])
    }

    @Test func refreshOnMissingDirectoryYieldsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "does-not-exist-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        let lib = library(at: missing)
        lib.refresh()
        #expect(lib.recordings.isEmpty)
    }

    @Test func deleteRemovesFolderAndRefreshes() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let folderURL = try Fixtures.recordingFolder(in: temp.url, name: "to-delete")
        let lib = library(at: temp.url)
        lib.refresh()
        let item = try #require(lib.recordings.first)
        lib.delete(item)
        #expect(lib.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folderURL.path))
    }
}
```

Note: `deleteRemovesFolderAndRefreshes` moves a throwaway temp folder to the user Trash (the production `delete` uses `trashItem`). It leaves one recoverable item in the Trash per run — expected and acceptable.

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/RecordingsLibraryTests
```

Expected: `TEST SUCCEEDED`, 4 tests passed.

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/RecordingsLibraryTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add RecordingsLibrary scanning and deletion tests"
```

---

## Task 13: `AudioFileWriter` tests

Tests the serial-queue audio writer with synthetic buffers — no capture hardware.

**Files:**
- Create: `audio-pipelineTests/AudioFileWriterTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/AudioFileWriterTests.swift`:

```swift
import Testing
import AVFoundation
import Foundation
@testable import audio_pipeline

@Suite struct AudioFileWriterTests {

    @Test func writesEnqueuedBuffersAndReportsFrameCount() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = temp.url.appending(path: "out.caf", directoryHint: .notDirectory)
        let format = SyntheticAudio.format(sampleRate: 48_000, channels: 1)

        let writer = try AudioFileWriter(url: url, format: format, label: "test")
        for _ in 0..<4 {
            writer.enqueue(SyntheticAudio.buffer(format: format, frames: 4096))
        }
        let frames = writer.close()   // close() drains the queue synchronously
        #expect(frames == Int64(4 * 4096))

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == Int64(4 * 4096))
    }

    @Test func enqueueAfterCloseIsIgnoredAndCloseIsIdempotent() throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let url = temp.url.appending(path: "out.caf", directoryHint: .notDirectory)
        let format = SyntheticAudio.format(sampleRate: 48_000, channels: 1)

        let writer = try AudioFileWriter(url: url, format: format, label: "test")
        writer.enqueue(SyntheticAudio.buffer(format: format, frames: 1024))
        let afterFirstClose = writer.close()

        writer.enqueue(SyntheticAudio.buffer(format: format, frames: 1024))
        let afterSecondClose = writer.close()

        #expect(afterFirstClose == 1024)
        #expect(afterSecondClose == afterFirstClose)
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/AudioFileWriterTests
```

Expected: `TEST SUCCEEDED`, 2 tests passed.

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/AudioFileWriterTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add AudioFileWriter tests with synthetic audio"
```

---

## Task 14: `FLACExporter` tests

Tests CAF→FLAC conversion with synthetic audio — the regression guard for the crash fixed in commit `e775746`.

**Files:**
- Create: `audio-pipelineTests/FLACExporterTests.swift`
- Modify (by script): `audio-pipeline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the tests**

Create `audio-pipelineTests/FLACExporterTests.swift`:

```swift
import Testing
import AVFoundation
import Foundation
@testable import audio_pipeline

@Suite struct FLACExporterTests {

    @Test func exportsTo16kMonoFLAC() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let source = temp.url.appending(path: "in.caf", directoryHint: .notDirectory)
        let destination = temp.url.appending(path: "out.flac", directoryHint: .notDirectory)
        try SyntheticAudio.writeCAF(to: source, sampleRate: 48_000, channels: 2, frames: 48_000)

        try await FLACExporter.export(from: source, to: destination)

        let output = try AVAudioFile(forReading: destination)
        #expect(output.fileFormat.sampleRate == 16_000)
        #expect(output.fileFormat.channelCount == 1)
        // 1 s of 48 kHz resampled to 16 kHz ≈ 16 000 frames.
        #expect(output.length > 15_000 && output.length < 17_000)
    }

    @Test func exportOfEmptyInputDoesNotCrash() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let source = temp.url.appending(path: "empty.caf", directoryHint: .notDirectory)
        let destination = temp.url.appending(path: "empty.flac", directoryHint: .notDirectory)
        try SyntheticAudio.writeCAF(to: source, sampleRate: 48_000, channels: 2, frames: 0)

        try await FLACExporter.export(from: source, to: destination)

        let output = try AVAudioFile(forReading: destination)
        #expect(output.length == 0)
    }

    @Test func exportOfVeryShortInputDoesNotCrash() async throws {
        let temp = TempDirectory()
        defer { temp.cleanup() }
        let source = temp.url.appending(path: "short.caf", directoryHint: .notDirectory)
        let destination = temp.url.appending(path: "short.flac", directoryHint: .notDirectory)
        try SyntheticAudio.writeCAF(to: source, sampleRate: 48_000, channels: 2, frames: 64)

        try await FLACExporter.export(from: source, to: destination)

        let output = try AVAudioFile(forReading: destination)
        #expect(output.length >= 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bash scripts/run-setup-tests.sh`, then:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests/FLACExporterTests
```

Expected: `TEST SUCCEEDED`, 3 tests passed.

- [ ] **Step 3: Commit**

```bash
git add audio-pipelineTests/FLACExporterTests.swift audio-pipeline.xcodeproj/project.pbxproj
git commit -m "test: add FLACExporter conversion tests"
```

---

## Final verification

After all 14 tasks, run the **entire** automated suite:

```bash
xcodebuild test \
  -project audio-pipeline.xcodeproj -scheme audio-pipeline \
  -destination 'platform=macOS' -derivedDataPath /tmp/audio-pipeline-build \
  OTHER_SWIFT_FLAGS=-disable-sandbox \
  -only-testing:audio-pipelineTests
```

Expected: `TEST SUCCEEDED` — roughly 62 tests across 11 suites, all passing, with no microphone, no permissions, and no network.

Then run the **manual smoke test** from spec §6 on a Mac with a microphone — it covers `MicRecorder`, `ProcessTapRecorder`, `AudioCapturePermission`, `RecordingSession`, and the live `AppCoordinator` driver, which are out of scope for automated tests:

1. Launch the app; confirm it appears in the menu bar, no Dock icon.
2. Start recording; grant the microphone and system-audio prompts on first run.
3. Play audio for a few seconds, speak into the mic, stop recording.
4. Confirm a timestamped folder under the recordings directory contains `mic.caf`, `system.caf` (or their `.flac` per the output-format setting), and `meta.json`.
5. Confirm `meta.json` has plausible durations and non-zero `framesWritten`.
6. With output format Convert-to-FLAC, confirm `.caf` files are removed; with Keep-both, confirm both remain.
7. Open the Recordings window; confirm the new recording is listed with the right size and duration.

Once everything passes, use the `superpowers:finishing-a-development-branch` skill to integrate the `test-coverage` branch.
