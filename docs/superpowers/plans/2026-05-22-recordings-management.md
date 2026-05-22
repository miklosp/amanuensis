# Recordings Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move recordings to a visible, user-configurable location, add a Recordings window, and add a `caf`/`flac`/`both` output-format setting that produces per-track 16 kHz mono FLAC.

**Architecture:** A new `AppSettings` (UserDefaults-backed, `@Observable`) holds the recordings location and output format. `RecordingStore` takes its base URL from settings instead of hardcoding it. After a recording stops, `AppCoordinator` runs `FLACExporter` asynchronously per the format setting. A new `RecordingsLibrary` scans the folder for the new Recordings `Window`; a `Settings` scene exposes the two preferences.

**Tech Stack:** Swift, SwiftUI (`MenuBarExtra`, `Settings`, `Window`, `Table`), AVFoundation (`AVAudioFile`, `AVAudioConverter`, `kAudioFormatFLAC`), `os.Logger`. No third-party packages.

**Spec:** `docs/superpowers/specs/2026-05-21-recordings-management-design.md`

**Verification:** No test target exists (`CLAUDE.md`); each task is verified by building and a manual check.
Build command used throughout:
```
cd ~/Documents/GitHub/audio-pipeline && xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build build 2>&1 | tail -4
```
Expected: `** BUILD SUCCEEDED **`.

**Commits:** The user is handling commits separately. Each task's checkpoint is a natural commit boundary, but do not run `git commit` unless the user asks.

---

## File Structure

**New files** (dropped into `audio-pipeline/` — the synchronized group picks them up automatically):
- `audio-pipeline/Settings/AppSettings.swift` — preferences model + `OutputFormat` enum.
- `audio-pipeline/Audio/FLACExporter.swift` — one CAF track → 16 kHz mono FLAC.
- `audio-pipeline/Storage/RecordingsLibrary.swift` — scans recordings, `RecordingItem` model.
- `audio-pipeline/UI/SettingsView.swift` — the Settings form.
- `audio-pipeline/UI/RecordingsView.swift` — the recordings table.

**Modified files:**
- `audio-pipeline/Storage/RecordingStore.swift` — base URL injected.
- `audio-pipeline/AppCoordinator.swift` — owns `AppSettings` + `RecordingsLibrary`; triggers FLAC export.
- `audio-pipeline/audio_pipelineApp.swift` — adds `Settings` and `Window` scenes.
- `audio-pipeline/UI/MenuBarContent.swift` — adds "Recordings…" and "Settings…" items.

---

## Task 1: AppSettings + OutputFormat

**Files:**
- Create: `audio-pipeline/Settings/AppSettings.swift`

- [ ] **Step 1: Create `AppSettings.swift`**

```swift
import Foundation
import Observation

// User preferences, persisted to UserDefaults. MainActor-isolated by the
// project's default actor isolation; observed by the Settings UI.
@Observable
final class AppSettings {
    enum OutputFormat: String, CaseIterable, Identifiable {
        case caf
        case flac
        case both

        var id: String { rawValue }

        var title: String {
            switch self {
            case .caf:  return "Keep raw (.caf)"
            case .flac: return "Convert to FLAC"
            case .both: return "Keep both"
            }
        }
    }

    var recordingsDirectory: URL {
        didSet {
            defaults.set(recordingsDirectory.path(percentEncoded: false),
                         forKey: Keys.recordingsDirectory)
        }
    }

    var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    static let defaultRecordingsDirectory: URL = URL.musicDirectory
        .appending(path: "audio-pipeline", directoryHint: .isDirectory)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let path = defaults.string(forKey: Keys.recordingsDirectory) {
            recordingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            recordingsDirectory = Self.defaultRecordingsDirectory
        }

        if let raw = defaults.string(forKey: Keys.outputFormat),
           let format = OutputFormat(rawValue: raw) {
            outputFormat = format
        } else {
            outputFormat = .caf
        }
    }

    private enum Keys {
        static let recordingsDirectory = "recordingsDirectory"
        static let outputFormat = "outputFormat"
    }
}
```

- [ ] **Step 2: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Checkpoint** — `AppSettings` compiles; nothing uses it yet.

---

## Task 2: RecordingStore takes its base URL from settings

This makes recordings land in `~/Music/audio-pipeline/`.

**Files:**
- Modify: `audio-pipeline/Storage/RecordingStore.swift`
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Change `RecordingStore.init` to accept a base URL**

Replace the `init()` in `RecordingStore.swift` (the struct's current initializer, which hardcodes the Application Support path) with:

```swift
    init(baseURL: URL) {
        self.baseURL = baseURL
    }
```

Leave `makeRecordingFolder`, `revealInFinder`, `folderName`, and `RecordingFolder` unchanged.

- [ ] **Step 2: Give `AppCoordinator` an `AppSettings` and build the store from it**

In `AppCoordinator.swift`, remove the stored property `private let store = RecordingStore()` and add, near the other stored properties:

```swift
    let settings: AppSettings

    init() {
        self.settings = AppSettings()
    }
```

- [ ] **Step 3: Build the store on demand in `startRecording()` and `openRecordingsFolder()`**

In `startRecording()`, replace `folder = try store.makeRecordingFolder(label: nil)` with a store built from settings:

```swift
        let folder: RecordingFolder
        do {
            let store = RecordingStore(baseURL: settings.recordingsDirectory)
            folder = try store.makeRecordingFolder(label: nil)
        } catch {
            lastError = "Couldn't create recording folder: \(error.localizedDescription)"
            status = .idle
            return
        }
```

In `openRecordingsFolder()`, replace `store.revealInFinder()` with:

```swift
        RecordingStore(baseURL: settings.recordingsDirectory).revealInFinder()
```

- [ ] **Step 4: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual check**

Launch the build, record ~5 s, stop. Confirm a new recording folder appears under `~/Music/audio-pipeline/` (not Application Support):
```
ls -dt ~/Music/audio-pipeline/*/ | head -1
```

- [ ] **Step 6: Checkpoint** — recordings now write to `~/Music/audio-pipeline/`.

---

## Task 3: FLACExporter

**Files:**
- Create: `audio-pipeline/Audio/FLACExporter.swift`

- [ ] **Step 1: Create `FLACExporter.swift`**

```swift
import AVFoundation
import Foundation

// Converts one recorded CAF track to a 16 kHz mono 16-bit FLAC. Runs off the
// main actor; used after a recording stops. AVAudioConverter handles the
// 48 kHz->16 kHz resample and the stereo->mono down-mix in one pass.
enum FLACExporter {
    enum ExportError: Error {
        case targetFormatUnavailable
        case converterUnavailable
        case bufferAllocationFailed
    }

    nonisolated static func export(from source: URL, to destination: URL) async throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw ExportError.targetFormatUnavailable
        }

        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        let outputFile = try AVAudioFile(forWriting: destination, settings: flacSettings)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ExportError.converterUnavailable
        }

        let outputCapacity: AVAudioFrameCount = 8_192
        var finished = false

        while !finished {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw ExportError.bufferAllocationFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: packetCount
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: inputBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError { throw conversionError }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }

            if status == .endOfStream || status == .error {
                finished = true
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Checkpoint** — `FLACExporter` compiles; wired in by Task 5. (Its real verification is the Task 5 manual check.)

---

## Task 4: RecordingsLibrary + RecordingItem

**Files:**
- Create: `audio-pipeline/Storage/RecordingsLibrary.swift`
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Create `RecordingsLibrary.swift`**

```swift
import Foundation
import Observation

// The model behind the Recordings window. Scans the recordings directory and
// parses each recording's meta.json into a list sorted newest-first.
@Observable
final class RecordingsLibrary {
    private(set) var recordings: [RecordingItem] = []

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func refresh() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: settings.recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            recordings = []
            return
        }

        recordings = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { RecordingItem(folderURL: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    // Deletes a recording by moving its whole folder to the Trash (recoverable).
    func delete(_ item: RecordingItem) {
        try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        refresh()
    }
}

struct RecordingItem: Identifiable {
    let id: String
    let name: String
    let folderURL: URL
    let startedAt: Date
    let duration: Double?
    let sizeBytes: Int64
    let formatSummary: String

    init?(folderURL: URL) {
        let metadataURL = folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: metadataURL),
              let meta = try? Self.decoder.decode(RecordingMetadata.self, from: data) else {
            return nil
        }

        id = meta.folderName
        name = meta.folderName
        self.folderURL = folderURL
        startedAt = meta.startedAt
        duration = meta.durationSeconds

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        var total: Int64 = 0
        var hasCAF = false
        var hasFLAC = false
        for file in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            switch file.pathExtension.lowercased() {
            case "caf":  hasCAF = true
            case "flac": hasFLAC = true
            default:     break
            }
        }
        sizeBytes = total
        formatSummary = [hasCAF ? "caf" : nil, hasFLAC ? "flac" : nil]
            .compactMap { $0 }
            .joined(separator: " + ")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

- [ ] **Step 2: Have `AppCoordinator` own a `RecordingsLibrary`**

In `AppCoordinator.swift`, add a `library` stored property and update `init()` to construct it from the same settings instance:

```swift
    let settings: AppSettings
    let library: RecordingsLibrary

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = RecordingsLibrary(settings: settings)
    }
```

- [ ] **Step 3: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Checkpoint** — library model compiles and is owned by the coordinator; surfaced by Task 6.

---

## Task 5: Run FLAC export after a recording stops

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

- [ ] **Step 1: Add a post-stop export method**

In `AppCoordinator.swift`, add this method to the class. It converts each track per the format setting; on success in `.flac` mode it removes the CAF. The CAF is never removed if its export fails.

```swift
    // Runs after a recording stops. Converts mic/system tracks to FLAC per the
    // output-format setting, then refreshes the recordings list.
    private func runOutputConversion(for folder: RecordingFolder) async {
        let format = settings.outputFormat
        guard format != .caf else {
            library.refresh()
            return
        }

        let tracks: [(caf: URL, flac: URL)] = [
            (folder.micURL,
             folder.url.appending(path: "mic.flac", directoryHint: .notDirectory)),
            (folder.systemURL,
             folder.url.appending(path: "system.flac", directoryHint: .notDirectory)),
        ]

        for track in tracks {
            guard FileManager.default.fileExists(atPath: track.caf.path) else { continue }
            do {
                try await FLACExporter.export(from: track.caf, to: track.flac)
                if format == .flac {
                    try? FileManager.default.removeItem(at: track.caf)
                }
            } catch {
                lastError = "FLAC conversion failed: \(error.localizedDescription)"
                Self.log.error("FLAC export failed for \(track.caf.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        library.refresh()
    }
```

- [ ] **Step 2: Call it from `stopRecording()`**

In `stopRecording()`, after `session = nil` and `status = .idle`, capture the folder and spawn the conversion. The current tail of `stopRecording()`:

```swift
        let result = active.stop()
        session = nil
        status = .idle
        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")
```

becomes:

```swift
        let folder = active.folder
        let result = active.stop()
        session = nil
        status = .idle
        Self.log.info("recording stopped — mic frames \(result.mic.framesWritten, privacy: .public), system frames \(result.system?.framesWritten ?? -1, privacy: .public)")
        Task { await runOutputConversion(for: folder) }
```

(`RecordingSession.folder` is already a `let` on the class, so it is accessible.)

- [ ] **Step 3: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual check — all three modes**

For each setting value, set `outputFormat` (Task 6 adds the UI; until then set it via `defaults write work.miklos.audio-pipeline outputFormat <caf|flac|both>` before launch), record ~10 s with audio playing, stop, and inspect the newest folder under `~/Music/audio-pipeline/`:
- `caf` → only `mic.caf`, `system.caf`, `meta.json`.
- `flac` → only `mic.flac`, `system.flac`, `meta.json` (CAFs removed).
- `both` → all four audio files.

Verify a produced FLAC is correct:
```
afinfo ~/Music/audio-pipeline/<latest>/system.flac
```
Expected: `1 ch, 16000 Hz`, duration matching the recording.

- [ ] **Step 5: Checkpoint** — output conversion works in all three modes.

---

## Task 6: Settings scene

**Files:**
- Create: `audio-pipeline/UI/SettingsView.swift`
- Modify: `audio-pipeline/audio_pipelineApp.swift`
- Modify: `audio-pipeline/UI/MenuBarContent.swift`

- [ ] **Step 1: Create `SettingsView.swift`**

```swift
import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(settings.recordingsDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseLocation)
                    }
                }
            }
            Section("Output format") {
                Picker("When a recording stops", selection: $settings.outputFormat) {
                    ForEach(AppSettings.OutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingsDirectory = url
        }
    }
}
```

- [ ] **Step 2: Add the `Settings` scene**

In `audio_pipelineApp.swift`, add a `Settings` scene after the `MenuBarExtra` (inside `body`):

```swift
        Settings {
            SettingsView(settings: coordinator.settings)
        }
```

- [ ] **Step 3: Add a "Settings…" menu item**

In `MenuBarContent.swift`, add a `SettingsLink` above the `Quit` divider:

```swift
            Divider()

            SettingsLink {
                Text("Settings…")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
```

- [ ] **Step 4: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual check**

Launch the build. Open Settings via the menu item and via ⌘,. Confirm: the location row shows `~/Music/audio-pipeline`, "Choose…" opens a folder panel and updates the row, the output-format radio shows three options and the selection survives an app relaunch.

- [ ] **Step 6: Checkpoint** — Settings scene works and persists.

---

## Task 7: Recordings window

**Files:**
- Create: `audio-pipeline/UI/RecordingsView.swift`
- Modify: `audio-pipeline/audio_pipelineApp.swift`
- Modify: `audio-pipeline/UI/MenuBarContent.swift`

- [ ] **Step 1: Create `RecordingsView.swift`**

```swift
import AppKit
import SwiftUI

struct RecordingsView: View {
    @Bindable var library: RecordingsLibrary
    @State private var selection: RecordingItem.ID?
    @State private var pendingDelete: RecordingItem?

    var body: some View {
        Table(library.recordings, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Date") { Text($0.startedAt, format: .dateTime) }
            TableColumn("Duration") { Text(Self.durationText($0.duration)) }
            TableColumn("Size") { Text(Self.sizeText($0.sizeBytes)) }
            TableColumn("Format", value: \.formatSummary)
        }
        .frame(minWidth: 620, minHeight: 320)
        .onAppear { library.refresh() }
        .contextMenu(forSelectionType: RecordingItem.ID.self) { ids in
            if let item = ids.first.flatMap(item(for:)) {
                Button("Play") { play(item) }
                Button("Reveal in Finder") { reveal(item) }
                Button("Delete…", role: .destructive) { pendingDelete = item }
            }
        }
        .alert(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Move to Trash", role: .destructive) { library.delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording folder will be moved to the Trash.")
        }
        .toolbar {
            Button {
                library.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func item(for id: RecordingItem.ID) -> RecordingItem? {
        library.recordings.first { $0.id == id }
    }

    // Opens the system track if present, otherwise the mic track.
    private func play(_ item: RecordingItem) {
        let candidates = ["system.flac", "system.caf", "mic.flac", "mic.caf"]
        for name in candidates {
            let url = item.folderURL.appending(path: name, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
    }

    private static func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
```

The alert derives its `isPresented` binding from the optional `pendingDelete`, so dismissing it (button or Escape) clears the pending item.

- [ ] **Step 2: Add the `Window` scene**

In `audio_pipelineApp.swift`, add after the `Settings` scene:

```swift
        Window("Recordings", id: "recordings") {
            RecordingsView(library: coordinator.library)
        }
```

- [ ] **Step 3: Add a "Recordings…" menu item**

In `MenuBarContent.swift`, add `@Environment(\.openWindow) private var openWindow` as a property of the struct, then add a button next to the existing "Open recordings folder" button:

```swift
            Button("Recordings…") {
                openWindow(id: "recordings")
            }
```

- [ ] **Step 4: Build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual check**

Launch the build. Open the Recordings window from the menu item. Confirm: existing recordings list with name, date, duration, size, and format; the toolbar refresh button works; right-click → Play opens audio in the default app; Reveal opens Finder with the folder selected; Delete… shows a confirmation and moves the folder to the Trash. Record a new clip and confirm it appears (the window refreshes after conversion finishes).

- [ ] **Step 6: Checkpoint** — Recordings window complete; all three features delivered.

---

## Done

All spec requirements implemented: `~/Music` location with a Settings control, the Recordings window, and the `caf`/`flac`/`both` per-track 16 kHz mono FLAC output. Verify the full flow once more end-to-end in `both` mode, then hand back to the user for commits.
