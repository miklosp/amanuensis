# Unified App Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the standalone `Window("Recordings")` scene with a single unified `NavigationSplitView`-based window. Sidebar destinations: Recordings, Jobs. Sidebar bottom: in-flight activity that collapses when idle. Settings is trimmed to recording prefs; Job CRUD moves into the Jobs destination. MenuBarExtra stays.

**Architecture:** `NavigationSplitView { Sidebar } detail: { … switch destination … }`. Jobs detail uses `HSplitView` (list + inline editor). `JobEditorView` is converted from a sheet to an inline pane. Dock icon flips between `.regular` (window open) and `.accessory` (window closed) via an `NSWindowDelegate` chained onto SwiftUI's own delegate.

**Tech Stack:** Swift 6.2, SwiftUI on macOS 26.3 (Liquid Glass), Swift Testing for SPM, XCTest for app-hosted. Build via Xcode; SPM tests via `swift test --disable-sandbox`; app build/test via `./scripts/xcode-build-helper.sh`.

**Reference spec:** `docs/superpowers/specs/2026-05-29-unified-app-window-design.md`

---

## File Structure

### Added

- `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift` — append static `Job.makeDraft(presets:)` factory.
- `audio-pipeline/UI/MainWindowView.swift` — owns the `NavigationSplitView`, the `SidebarDestination` enum, sidebar selection state, and destination routing.
- `audio-pipeline/UI/Sidebar/SidebarActivityBar.swift` — sidebar bottom bar (`ActivityRow` + the conditional collapse).
- `audio-pipeline/UI/WindowAccessor.swift` — `NSViewRepresentable` that surfaces the hosting `NSWindow` via a callback.
- `audio-pipeline/UI/MainWindowLifecycleDelegate.swift` — `NSWindowDelegate` that toggles `NSApp.activationPolicy` based on main-window lifecycle, chaining onto any pre-existing delegate.
- `audio-pipeline/UI/Jobs/JobsView.swift` — `HSplitView` list + inline editor for the Jobs destination.
- `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift` — Swift Testing suite for the new factory.

### Modified

- `audio-pipeline/audio_pipelineApp.swift` — swap `Window("Recordings", id: "recordings")` for `Window("Audio Pipeline", id: "main")`; add `.defaultSize` and `.commands { CommandGroup(replacing: .newItem) { OpenMainWindowCommand() } }`; trim `SettingsView` args.
- `audio-pipeline/UI/RecordingsView.swift` — drop outer `VStack`, both `StatusFooterRow` blocks, `frame(minWidth:minHeight:)`, the local `StatusFooterRow` type.
- `audio-pipeline/UI/SettingsView.swift` — collapse `TabView` to a single inline `Form`; drop `presets`, `jobs`, `keychain` parameters.
- `audio-pipeline/UI/MenuBarContent.swift` — replace the "Recordings…" button with "Open Window" pointed at `id: "main"`.
- `audio-pipeline/UI/Jobs/JobEditorView.swift` — convert from sheet to inline editor: remove `@Environment(\.dismiss)`, Cancel button, `dismiss()` from `save()`, fixed `.frame(width:height:)`, and the `initial == nil` branch in `init`. Always require a non-nil `Job`.
- `audio-pipeline/AppCoordinator.swift` — wrap `recordingActivity` / `jobActivity` mutations in `withAnimation { … }` so the sidebar bar animates in/out cleanly.

### Deleted

- `audio-pipeline/UI/Jobs/JobsSettingsPanel.swift` — superseded by `JobsView.swift`. Removal handled by the `PBXFileSystemSynchronizedRootGroup`.

---

## Verification commands (used throughout)

- **SPM build:** `swift build --package-path Packages/AudioPipeline`
- **SPM tests:** `swift test --disable-sandbox --package-path Packages/AudioPipeline`
- **App build:** `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build`
- **App tests:** `./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test`
- **Launch built app:** open Xcode and ⌘R, or `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app` (see CLAUDE.md for resolving `BUILT_PRODUCTS_DIR`).

The xcode-build helper script routes through the Hammerspoon daemon — see the `xcode-build` skill for context.

---

## Task 1: Add `Job.makeDraft(presets:)` factory (TDD on SPM)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift`
- Create: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift`

The current `JobEditorView.init` synthesises an `Untitled` draft inline when `initial == nil`. We move that logic to a static factory so the new `JobsView.addJob()` can call it and `JobEditorView` can drop its `nil` branch.

- [ ] **Step 1: Write the failing test**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobMakeDraft {
    @Test func usesFirstPresetWhenAvailable() {
        let preset = Preset(
            id: "openai-compat-chat",
            displayName: "OpenAI Compatible",
            shape: .chatCompletionsAudio,
            baseURL: "https://api.example/v1",
            suggestedModels: ["gpt-4o-audio", "gemini-flash"],
            defaults: ["temperature": "0.2", "prompt": "Transcribe"]
        )
        let presets = PresetsStore(presets: [preset])

        let draft = Job.makeDraft(presets: presets)

        #expect(draft.name == "Untitled")
        #expect(draft.presetID == "openai-compat-chat")
        #expect(draft.baseURL == "https://api.example/v1")
        #expect(draft.model == "gpt-4o-audio")
        #expect(draft.fields == ["temperature": "0.2", "prompt": "Transcribe"])
        #expect(draft.outputExt == "txt")
        #expect(draft.apiKeyRef.account == "")
        #expect(draft.outputFolderPath == nil)
    }

    @Test func fallsBackToEmptyDefaultsWhenNoPresets() {
        let presets = PresetsStore(presets: [])

        let draft = Job.makeDraft(presets: presets)

        #expect(draft.name == "Untitled")
        #expect(draft.presetID == "")
        #expect(draft.baseURL == "")
        #expect(draft.model == "")
        #expect(draft.fields == [:])
        #expect(draft.outputExt == "txt")
        #expect(draft.apiKeyRef.account == "")
    }

    @Test func assignsDistinctIDsPerCall() {
        let presets = PresetsStore(presets: [])
        let a = Job.makeDraft(presets: presets)
        let b = Job.makeDraft(presets: presets)
        #expect(a.id != b.id)
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobMakeDraft
```

Expected: build fails with `type 'Job' has no member 'makeDraft'`.

- [ ] **Step 3: Implement the factory**

Append to `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift` (after the `init` closing brace, before the type's closing brace):

```swift
    public static func makeDraft(presets: PresetsStore) -> Job {
        let firstPreset = presets.all.first
        return Job(
            name: "Untitled",
            presetID: firstPreset?.id ?? "",
            baseURL: firstPreset?.baseURL ?? "",
            model: firstPreset?.suggestedModels.first ?? "",
            apiKeyRef: KeychainRef(account: ""),
            fields: firstPreset?.defaults ?? [:],
            outputExt: "txt"
        )
    }
```

- [ ] **Step 4: Re-run the test, confirm it passes**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline --filter JobMakeDraft
```

Expected: 3 tests pass.

- [ ] **Step 5: Run the full SPM test suite to confirm no regression**

```bash
swift test --disable-sandbox --package-path Packages/AudioPipeline
```

Expected: all existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobMakeDraftTests.swift
git commit -m "$(cat <<'EOF'
feat(jobs): add Job.makeDraft(presets:) factory

Lifts the draft-job synthesis out of JobEditorView.init so the upcoming
inline Jobs view can construct drafts at the call site. JobEditorView
will then require a non-nil Job.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Trim `SettingsView` to recording prefs only

**Files:**
- Modify: `audio-pipeline/UI/SettingsView.swift`
- Modify: `audio-pipeline/audio_pipelineApp.swift`

After this task, `JobsSettingsPanel.swift` is orphaned (still on disk, no caller). The project must still build.

- [ ] **Step 1: Rewrite `SettingsView.swift`**

Replace the entire contents of `audio-pipeline/UI/SettingsView.swift` with:

```swift
import AppKit
import AppSettings
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
            Section("After recording stops") {
                Toggle(isOn: $settings.keepOriginalCAF) {
                    VStack(alignment: .leading) {
                        Text("Keep original .caf recordings")
                        Text("Combined .flac is always produced. Disable this to delete the raw mic/system .caf files after combining.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
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

- [ ] **Step 2: Update the `SettingsView` call site in `audio_pipelineApp.swift`**

Find the `Settings { … }` scene in `audio-pipeline/audio_pipelineApp.swift` and change it from:

```swift
Settings {
    SettingsView(settings: coordinator.settings,
                 presets: coordinator.presets,
                 jobs: coordinator.jobs,
                 keychain: coordinator.keychain)
}
```

to:

```swift
Settings {
    SettingsView(settings: coordinator.settings)
}
```

Also remove the now-unused imports if needed. Run the build (next step) to confirm; do not pre-emptively prune imports.

- [ ] **Step 3: Build the app to confirm it compiles**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. `JobsSettingsPanel.swift` is now unreferenced but still on disk — that is fine for one commit boundary.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/UI/SettingsView.swift audio-pipeline/audio_pipelineApp.swift
git commit -m "$(cat <<'EOF'
refactor(settings): drop Jobs tab from SettingsView

Settings becomes recording-prefs-only as part of the unified-window
move. JobsSettingsPanel is orphaned by this commit and removed in a
follow-up.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Delete `JobsSettingsPanel.swift`

**Files:**
- Delete: `audio-pipeline/UI/Jobs/JobsSettingsPanel.swift`

- [ ] **Step 1: Delete the file**

```bash
git rm audio-pipeline/UI/Jobs/JobsSettingsPanel.swift
```

- [ ] **Step 2: Build the app to confirm nothing referenced it**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. (`PBXFileSystemSynchronizedRootGroup` picks up the removal automatically — no pbxproj edit required.)

- [ ] **Step 3: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor(jobs): delete unused JobsSettingsPanel

Replaced by JobsView in an upcoming commit. Pre-deletion keeps the
intermediate compile state clean and avoids JobEditorView API churn
showing up against a dead caller.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Convert `JobEditorView` from sheet to inline editor

**Files:**
- Modify: `audio-pipeline/UI/Jobs/JobEditorView.swift`

At this point `JobEditorView` is unreferenced (removed with `JobsSettingsPanel`), so we can change its API freely. After this task it has no callers — `JobsView` (next task) brings it back online.

- [ ] **Step 1: Rewrite `JobEditorView.swift`**

Replace the entire contents of `audio-pipeline/UI/Jobs/JobEditorView.swift` with:

```swift
import AppKit
import AudioPipelineJobs
import SwiftUI

struct JobEditorView: View {
    @State private var name: String
    @State private var presetID: String
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKeyAccount: String
    @State private var fields: [String: String]
    @State private var outputExt: String
    @State private var customOutputFolder: Bool
    @State private var outputFolderPath: String

    private let initialID: UUID
    private let presets: PresetsStore
    private let keychain: KeychainStore
    private let onSave: (Job) -> Void

    init(initial: Job, presets: PresetsStore, keychain: KeychainStore,
         onSave: @escaping (Job) -> Void) {
        self.presets = presets
        self.keychain = keychain
        self.onSave = onSave

        self.initialID = initial.id
        _name = State(initialValue: initial.name)
        _presetID = State(initialValue: initial.presetID)
        _baseURL = State(initialValue: initial.baseURL)
        _model = State(initialValue: initial.model)
        _apiKeyAccount = State(initialValue: initial.apiKeyRef.account)
        _fields = State(initialValue: initial.fields)
        _outputExt = State(initialValue: initial.outputExt)
        let startingFolder = initial.outputFolderPath ?? ""
        _customOutputFolder = State(initialValue: !startingFolder.isEmpty)
        _outputFolderPath = State(initialValue: startingFolder)
    }

    private var preset: Preset? { presets.preset(id: presetID) }
    private var shape: JobShape? { preset?.shape }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Job").font(.title2).padding([.top, .horizontal])

            Form {
                Section("General") {
                    TextField("Name", text: $name)
                    Picker("Preset", selection: $presetID) {
                        ForEach(presets.all) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    .onChange(of: presetID) { _, newID in
                        guard let p = presets.preset(id: newID) else { return }
                        baseURL = p.baseURL
                        if model.isEmpty { model = p.suggestedModels.first ?? "" }
                        for (k, v) in p.defaults where fields[k] == nil { fields[k] = v }
                    }
                    TextField("Base URL", text: $baseURL)
                    HStack {
                        TextField("Model", text: $model)
                        if let suggestions = preset?.suggestedModels, !suggestions.isEmpty {
                            Menu("Suggested") {
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { model = s }
                                }
                            }
                            .frame(width: 110)
                        }
                    }
                    KeychainAccountPicker(account: $apiKeyAccount, keychain: keychain)
                    TextField("Output extension", text: $outputExt)
                    Toggle(isOn: $customOutputFolder) {
                        Text("Custom output folder")
                    }
                    if customOutputFolder {
                        HStack {
                            Text(outputFolderPath.isEmpty ? "—" : outputFolderPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose…", action: chooseOutputFolder)
                        }
                    }
                }

                if let shape {
                    Section("Parameters") {
                        JobFieldFormView(shape: shape, values: $fields)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.glassProminent)
            }
            .padding(12)
        }
    }

    private var canSave: Bool {
        let folderOK = !customOutputFolder || !outputFolderPath.isEmpty
        return !name.isEmpty && !presetID.isEmpty && !apiKeyAccount.isEmpty
            && !model.isEmpty && folderOK
    }

    private func save() {
        let job = Job(id: initialID, name: name, presetID: presetID,
                      baseURL: baseURL, model: model,
                      apiKeyRef: KeychainRef(account: apiKeyAccount),
                      fields: fields, outputExt: outputExt,
                      outputFolderPath: customOutputFolder && !outputFolderPath.isEmpty
                          ? outputFolderPath : nil)
        onSave(job)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let url = URL(string: outputFolderPath), FileManager.default.fileExists(atPath: url.path) {
            panel.directoryURL = url
        }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }
}
```

Changes vs today:
- `init(initial:)` now requires a non-nil `Job` (was `Job?`). Draft synthesis lives in `Job.makeDraft(...)`.
- Dropped `@Environment(\.dismiss)` and the Cancel button.
- Dropped `dismiss()` from `save()`.
- Dropped `.frame(width: 540, height: 560)` — parent `HSplitView` controls width/height.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. `JobEditorView` is unreferenced but compiles standalone.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/Jobs/JobEditorView.swift
git commit -m "$(cat <<'EOF'
refactor(jobs): convert JobEditorView to an inline editor

Drops sheet-specific surface (Cancel button, dismiss(), fixed frame) and
the nil-initial draft branch. Callers always pass a real Job — drafts
come from Job.makeDraft. Wired back in by JobsView in the next commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Create `JobsView`

**Files:**
- Create: `audio-pipeline/UI/Jobs/JobsView.swift`

Now `JobEditorView` has a caller again, but `JobsView` is itself not yet wired into a scene — that happens when `MainWindowView` arrives.

- [ ] **Step 1: Create `JobsView.swift`**

```swift
import AudioPipelineJobs
import SwiftUI

struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    let keychain: KeychainStore

    @State private var selection: Job.ID?

    var body: some View {
        HSplitView {
            List(jobs.jobs, selection: $selection) { job in
                Text(job.name).tag(Optional(job.id))
            }
            .frame(minWidth: 200, idealWidth: 240)

            if let id = selection, let job = jobs.jobs.first(where: { $0.id == id }) {
                JobEditorView(initial: job,
                              presets: presets,
                              keychain: keychain,
                              onSave: { jobs.upsert($0) })
                    .id(job.id)
                    .frame(minWidth: 420)
            } else {
                ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
                    .frame(minWidth: 420)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
    }

    private func addJob() {
        let draft = Job.makeDraft(presets: presets)
        jobs.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        jobs.delete(id: id)
        selection = nil
    }
}
```

Notes:
- `.id(job.id)` forces SwiftUI to rebuild `JobEditorView` (re-seeding its `@State`) whenever the user switches selection.
- `Text(job.name).tag(Optional(job.id))` matches the `Binding<Job.ID?>` selection.
- Toolbar items are declared on the view body — they will surface in the parent window toolbar once `JobsView` is the active destination.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. `JobsView` exists but no scene references it yet — fine.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/Jobs/JobsView.swift
git commit -m "$(cat <<'EOF'
feat(jobs): add JobsView (HSplitView list + inline editor)

Replaces the deleted JobsSettingsPanel. New Job creates a draft via
Job.makeDraft and selects it; Delete drops the selected job. Editor
re-seeds on selection via .id(job.id).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Trim `RecordingsView` footer

**Files:**
- Modify: `audio-pipeline/UI/RecordingsView.swift`

The two `StatusFooterRow` blocks move out of the page footer (the sidebar bottom bar takes over in a later task). The outer `VStack` and the fixed `frame` come out too; the parent window enforces minimums.

- [ ] **Step 1: Rewrite `RecordingsView.swift`**

Replace the entire contents of `audio-pipeline/UI/RecordingsView.swift` with:

```swift
import AppKit
import AudioPipelineJobs
import RecordingStorage
import SwiftUI

struct RecordingsView: View {
    @Bindable var library: RecordingsLibrary
    let coordinator: AppCoordinator
    @State private var selection: Set<RecordingItem.ID> = []
    @State private var pendingDelete: RecordingItem?

    var body: some View {
        Table(library.recordings, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Date") { Text($0.startedAt, format: .dateTime) }
            TableColumn("Duration") { Text(RecordingFormatters.durationText($0.duration)) }
            TableColumn("Size") { Text(RecordingFormatters.sizeText($0.sizeBytes)) }
            TableColumn("Format", value: \.formatSummary)
        }
        .task { await library.refresh() }
        .contextMenu(forSelectionType: RecordingItem.ID.self) { ids in
            if let item = ids.first.flatMap(item(for:)) {
                Button("Play") { play(item) }
                Button("Reveal in Finder") { reveal(item) }

                if coordinator.jobs.jobs.isEmpty {
                    Text("No Jobs defined")
                } else {
                    Menu("Run Job") {
                        ForEach(coordinator.jobs.jobs) { job in
                            Button(job.name) {
                                Task {
                                    let result = await coordinator.runJob(job, on: item.folderURL)
                                    if case .success(let out) = result {
                                        NSWorkspace.shared.activateFileViewerSelecting([out])
                                    }
                                }
                            }
                        }
                    }
                }

                Button("Delete…", role: .destructive) { pendingDelete = item }
            }
        } primaryAction: { ids in
            if let item = ids.first.flatMap(item(for:)) {
                NSWorkspace.shared.open(item.folderURL)
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
            Button("Move to Trash", role: .destructive) {
                Task { await library.delete(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The recording folder will be moved to the Trash.")
        }
        .toolbar {
            Button {
                Task { await library.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func item(for id: RecordingItem.ID) -> RecordingItem? {
        library.recordings.first { $0.id == id }
    }

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
}
```

Removed: outer `VStack`, both `StatusFooterRow` calls, the per-page activity animation modifiers, `frame(minWidth: 620, minHeight: 320)`, and the local `StatusFooterRow` type.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. The existing `Window("Recordings", id: "recordings")` scene still renders this view — toolbar Refresh stays visible, footers are gone.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/RecordingsView.swift
git commit -m "$(cat <<'EOF'
refactor(recordings): drop page footer from RecordingsView

Activity status (recording conversion + job runs) moves to the
sidebar bottom bar in a later commit. Parent window enforces size
minimums, so the fixed frame goes too.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Create `SidebarActivityBar`

**Files:**
- Create: `audio-pipeline/UI/Sidebar/SidebarActivityBar.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct SidebarActivityBar: View {
    let coordinator: AppCoordinator

    var body: some View {
        if coordinator.recordingActivity == nil && coordinator.jobActivity == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let s = coordinator.recordingActivity {
                    ActivityRow(text: s)
                }
                if let s = coordinator.jobActivity {
                    ActivityRow(text: s)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 9))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ActivityRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}
```

Notes:
- `HStack(alignment: .firstTextBaseline, …)` puts the `ProgressView` on the first text line — important for the wrapping job-name row.
- Single `glassEffect` on the rounded container — no `GlassEffectContainer` needed; only one glass surface here.
- Deployment target is macOS 26.3, so no `#available` gate.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. View exists, no scene references it yet.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/Sidebar/SidebarActivityBar.swift
git commit -m "$(cat <<'EOF'
feat(ui): add SidebarActivityBar for in-flight status rows

Single Liquid-Glass capsule housing recording-conversion and job-run
status. Collapses to EmptyView when both activities are nil.
Progress spinner anchored to the first text baseline so it stays on
line 1 when the label wraps.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Create `WindowAccessor`

**Files:**
- Create: `audio-pipeline/UI/WindowAccessor.swift`

A small `NSViewRepresentable` that hands back the hosting `NSWindow` once it's available. Used by `MainWindowView` to attach the lifecycle delegate.

- [ ] **Step 1: Create the file**

```swift
import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onResolved: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolved(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolved(window)
            }
        }
    }
}
```

The `DispatchQueue.main.async` is deliberate: at `makeNSView` time the view is not yet in a window. The async hop gives AppKit a chance to attach it.

The callback may fire more than once. Callers must guard against repeated installs (`MainWindowLifecycleDelegate` does this with a `private var installed` flag — see next task).

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/WindowAccessor.swift
git commit -m "$(cat <<'EOF'
feat(ui): add WindowAccessor for surfacing the hosting NSWindow

Tiny NSViewRepresentable that calls back with the resolved NSWindow
once it's attached. Used by the upcoming main-window lifecycle
delegate.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Create `MainWindowLifecycleDelegate`

**Files:**
- Create: `audio-pipeline/UI/MainWindowLifecycleDelegate.swift`

`NSWindowDelegate` that flips `NSApp.activationPolicy` between `.accessory` (window closed) and `.regular` (window open). Chains onto SwiftUI's own delegate so default behaviour is preserved.

- [ ] **Step 1: Create the file**

```swift
import AppKit

@MainActor
final class MainWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private weak var previousDelegate: NSWindowDelegate?
    private var installed = false

    func install(on window: NSWindow) {
        guard !installed else { return }
        installed = true
        previousDelegate = window.delegate
        window.delegate = self

        // Window is already on screen by the time we install — bump policy now
        // so the dock icon appears on first open.
        NSApp.setActivationPolicy(.regular)
    }

    // MARK: - NSWindowDelegate forwarding

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        previousDelegate?.windowWillClose?(notification)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return previousDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if previousDelegate?.responds(to: aSelector) == true {
            return previousDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}
```

Notes:
- Policy flip on install (not `windowDidBecomeMain`) is intentional. SwiftUI's main window is already visible by the time `WindowAccessor` resolves; using `becomeMain` would skip the first appearance.
- `install(on:)` is idempotent — `WindowAccessor`'s callback may fire on every layout pass.
- The forwarding shims let any SwiftUI internal delegate behaviour keep working for messages we don't override (`windowDidResize`, etc.).

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/MainWindowLifecycleDelegate.swift
git commit -m "$(cat <<'EOF'
feat(ui): NSWindowDelegate flipping activation policy on main window

When the main window installs it bumps NSApp.activationPolicy to
.regular (dock icon appears) and on windowWillClose drops back to
.accessory. Forwards unhandled delegate messages to SwiftUI's own
delegate so default behaviour stays intact.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Create `MainWindowView`

**Files:**
- Create: `audio-pipeline/UI/MainWindowView.swift`

Owns the `NavigationSplitView`, routes between Recordings and Jobs, hosts the sidebar activity bar, and installs the lifecycle delegate on its `NSWindow`.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct MainWindowView: View {
    let coordinator: AppCoordinator

    @State private var selection: SidebarDestination = .recordings
    @State private var lifecycleDelegate = MainWindowLifecycleDelegate()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Recordings", systemImage: "waveform")
                        .tag(SidebarDestination.recordings)
                    Label("Jobs", systemImage: "wand.and.stars")
                        .tag(SidebarDestination.jobs)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarActivityBar(coordinator: coordinator)
            }
        } detail: {
            switch selection {
            case .recordings:
                RecordingsView(library: coordinator.library, coordinator: coordinator)
                    .navigationTitle("Recordings")
            case .jobs:
                JobsView(presets: coordinator.presets,
                         jobs: coordinator.jobs,
                         keychain: coordinator.keychain)
                    .navigationTitle("Jobs")
            }
        }
        .background {
            WindowAccessor { window in
                lifecycleDelegate.install(on: window)
            }
        }
    }
}

enum SidebarDestination: Hashable {
    case recordings, jobs
}
```

Notes:
- `@State private var lifecycleDelegate = MainWindowLifecycleDelegate()` keeps the delegate alive across body re-runs.
- `safeAreaInset(edge: .bottom)` with `SidebarActivityBar` ensures the bar floats below the sidebar list and collapses cleanly when its body becomes `EmptyView`.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. View is defined but no scene uses it yet.

- [ ] **Step 3: Commit**

```bash
git add audio-pipeline/UI/MainWindowView.swift
git commit -m "$(cat <<'EOF'
feat(ui): add MainWindowView (sidebar + content split)

NavigationSplitView with Recordings/Jobs destinations and the activity
bar pinned to the sidebar's bottom safe area. Installs
MainWindowLifecycleDelegate via WindowAccessor so the dock icon tracks
window presence.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Swap scenes in `audio_pipelineApp.swift` (window goes live)

**Files:**
- Modify: `audio-pipeline/audio_pipelineApp.swift`

This is the cutover. The standalone Recordings window goes away; the unified `main` window appears, wired with ⌘N via `CommandGroup(replacing: .newItem)`.

- [ ] **Step 1: Rewrite `audio_pipelineApp.swift`**

Replace the entire contents of `audio-pipeline/audio_pipelineApp.swift` with:

```swift
import AppSettings
import SwiftUI

@main
struct AudioPipelineApp: App {
    @NSApplicationDelegateAdaptor(AudioPipelineAppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.isRecording
                  ? "record.circle.fill"
                  : "waveform.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)

        Window("Audio Pipeline", id: "main") {
            MainWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 880, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenMainWindowCommand()
            }
        }

        Settings {
            SettingsView(settings: coordinator.settings)
        }
    }
}

private struct OpenMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "main")
        }
        .keyboardShortcut("n")
    }
}
```

Notes:
- `OpenMainWindowCommand` is a private View so it can capture `@Environment(\.openWindow)` — `.commands { … }` is a scene-level closure where the environment is not directly readable.
- The unused `AudioPipelineJobs`/`RecordingStorage` imports from the old file are dropped; their types are no longer referenced here.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Launch the app (manual)**

Open `audio-pipeline.xcodeproj` in Xcode and ⌘R, or `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`. Walk through:

- Cold launch → no dock icon, MenuBarExtra is present.
- (MenuBarContent still says "Recordings…" at this point — fixed in the next task. Clicking it currently does nothing useful because `Window(id: "recordings")` no longer exists. That's expected for one commit boundary.)
- File → New Window (⌘N from any focused state with the app frontmost) → the new window appears; dock icon appears.
- Close the window → dock icon disappears.
- ⌘, opens Settings as a separate window, now showing only the Recording prefs.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/audio_pipelineApp.swift
git commit -m "$(cat <<'EOF'
feat(app): replace Recordings window with unified main window

Window(\"Audio Pipeline\", id: \"main\") hosting MainWindowView replaces
the standalone recordings window. Adds ⌘N via CommandGroup(.newItem)
and a private OpenMainWindowCommand helper that reads
@Environment(\.openWindow).

MenuBarContent still points at the old window ID — fixed in the next
commit.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Update `MenuBarContent.swift`

**Files:**
- Modify: `audio-pipeline/UI/MenuBarContent.swift`

Replace the "Recordings…" button with "Open Window" pointed at `id: "main"`.

- [ ] **Step 1: Apply the edit**

In `audio-pipeline/UI/MenuBarContent.swift`, replace:

```swift
            Button("Recordings…") {
                openWindow(id: "recordings")
                NSApp.activate()
                // Raise the recordings window above other windows of this app.
                // Defer one runloop tick so openWindow has time to surface the window.
                DispatchQueue.main.async {
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "recordings" }) {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
            }
```

with:

```swift
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate()
                DispatchQueue.main.async {
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
            }
```

Everything else (statusLine, Start/Stop, Open last/recordings folder, error line, Settings…, Quit) is unchanged.

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Launch the app (manual)**

Walk through:

- Menu bar → "Open Window" → the unified window appears, dock icon appears.
- Close the window via the red dot → dock icon disappears.
- Menu bar → "Open Window" again → window comes back, dock icon comes back.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/UI/MenuBarContent.swift
git commit -m "$(cat <<'EOF'
feat(menubar): replace Recordings... with Open Window

Points the menu-bar item at the unified main window. Everything else
in the menu bar stays the same.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Animate sidebar bar in/out from `AppCoordinator`

**Files:**
- Modify: `audio-pipeline/AppCoordinator.swift`

Wrap the four mutations that toggle `recordingActivity` / `jobActivity` in `withAnimation { … }` so the sidebar bar slides in and out cleanly. No state-machine or service changes.

- [ ] **Step 1: Wrap the four assignments**

Edit `audio-pipeline/AppCoordinator.swift`. There are four lines to wrap:

1. In `stopRecording()` (around line 144):

   ```swift
   recordingActivity = "Converting recording…"
   ```

   becomes:

   ```swift
   withAnimation { recordingActivity = "Converting recording…" }
   ```

2. In `runJob(_:on:)` (around line 200):

   ```swift
   jobActivity = "Waiting for '\(recordingName)' to finish converting…"
   ```

   becomes:

   ```swift
   withAnimation { jobActivity = "Waiting for '\(recordingName)' to finish converting…" }
   ```

3. In `runJob(_:on:)` (around line 204):

   ```swift
   jobActivity = "Running '\(job.name)' on '\(recordingName)'…"
   ```

   becomes:

   ```swift
   withAnimation { jobActivity = "Running '\(job.name)' on '\(recordingName)'…" }
   ```

4. In `flashActivity(_:)` (around line 228) — wrap both the initial assignment AND the deferred clear:

   ```swift
   private func flashActivity(_ message: String) async {
       jobActivity = message
       let snapshot = message
       Task { @MainActor [weak self] in
           try? await Task.sleep(nanoseconds: 3_000_000_000)
           guard self?.jobActivity == snapshot else { return }
           self?.jobActivity = nil
       }
   }
   ```

   becomes:

   ```swift
   private func flashActivity(_ message: String) async {
       withAnimation { jobActivity = message }
       let snapshot = message
       Task { @MainActor [weak self] in
           try? await Task.sleep(nanoseconds: 3_000_000_000)
           guard self?.jobActivity == snapshot else { return }
           withAnimation { self?.jobActivity = nil }
       }
   }
   ```

5. Same change in `flashRecordingActivity(_:)` (around line 242):

   ```swift
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

   becomes:

   ```swift
   private func flashRecordingActivity(_ message: String) async {
       withAnimation { recordingActivity = message }
       let snapshot = message
       Task { @MainActor [weak self] in
           try? await Task.sleep(nanoseconds: 3_000_000_000)
           guard self?.recordingActivity == snapshot else { return }
           withAnimation { self?.recordingActivity = nil }
       }
   }
   ```

`import SwiftUI` is already implicit via re-exports — but if the build complains, add `import SwiftUI` at the top of `AppCoordinator.swift`. (Step 2 will catch this.)

- [ ] **Step 2: Build the app**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug build
```

Expected: BUILD SUCCEEDED. If the compiler complains about `withAnimation`, add `import SwiftUI` and re-run.

- [ ] **Step 3: Launch the app and exercise the activity bar (manual)**

- Start a recording from the menu bar; stop it.
- Watch the sidebar bottom: a glass capsule slides up with "Converting recording…", then either "Recording ready" or the failure message, then the capsule slides away ~3 s later.
- Open Jobs in the sidebar, create a job, then right-click a recording → Run Job. Watch the second activity row appear and slide away.

- [ ] **Step 4: Commit**

```bash
git add audio-pipeline/AppCoordinator.swift
git commit -m "$(cat <<'EOF'
fix(coordinator): animate sidebar activity transitions

Wraps the four recordingActivity/jobActivity mutations in
withAnimation so SidebarActivityBar slides in and out cleanly.
No state-machine or service changes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Smoke test for `SidebarDestination`

**Files:**
- Create: `audio-pipelineTests/MainWindowViewTests.swift`

The spec called for an XCTest smoke test. Asserting the live sidebar list from outside is fragile (SwiftUI view introspection is non-public), so the realistic surface for an automated test is the structural primitive — `SidebarDestination`. This stays cheap and catches accidental case removals.

Behavioural verification (window opens, sidebar lists Recordings/Jobs, switching destinations swaps the content) is on the manual checklist in Task 15.

- [ ] **Step 1: Create the test file**

```swift
import XCTest
@testable import audio_pipeline

final class MainWindowViewTests: XCTestCase {
    func test_sidebarDestination_hasExpectedCases() {
        let all: Set<SidebarDestination> = [.recordings, .jobs]
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains(.recordings))
        XCTAssertTrue(all.contains(.jobs))
    }

    func test_sidebarDestination_isHashable() {
        let dict: [SidebarDestination: String] = [
            .recordings: "Recordings",
            .jobs: "Jobs"
        ]
        XCTAssertEqual(dict[.recordings], "Recordings")
        XCTAssertEqual(dict[.jobs], "Jobs")
    }
}
```

If `SidebarDestination` is currently `internal`, leave it — `@testable import audio_pipeline` exposes it. The app target's product name as configured today is `audio_pipeline` (verify by inspecting `audio-pipelineTests/RecordingFormattersTests.swift`'s existing `@testable import`).

- [ ] **Step 2: Add the test to the project**

Run the project's `scripts/setup-tests.rb` if there is an add-tests entry, or — per the project's `setup-tests.rb is add-only` memory — verify whether the test file is auto-picked-up by the `audio-pipelineTests` target. Inspect `audio-pipeline.xcodeproj/project.pbxproj` to confirm new files in `audio-pipelineTests/` are sync'd automatically.

If not auto-sync'd, use the script per `CLAUDE.md`. If neither path applies (the script is add-only but the test target uses a synchronized group), the test will be picked up on next build with no action needed.

- [ ] **Step 3: Run the app-hosted tests**

```bash
./scripts/xcode-build-helper.sh -project audio-pipeline.xcodeproj -scheme audio-pipeline -destination 'platform=macOS' test
```

Expected: all tests pass, including the two new ones.

- [ ] **Step 4: Commit**

```bash
git add audio-pipelineTests/MainWindowViewTests.swift
# also stage any pbxproj change if setup-tests.rb edited it
git status
git add audio-pipeline.xcodeproj/project.pbxproj 2>/dev/null || true
git commit -m "$(cat <<'EOF'
test: cover SidebarDestination cases

Cheap structural test to catch accidental removal of sidebar
destinations. Behavioural verification of the live sidebar is on the
manual checklist.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: Cold launch sanity**

- Launch the app from Xcode (⌘R) or `open <BUILT_PRODUCTS_DIR>/audio-pipeline.app`.
- ✅ No dock icon.
- ✅ MenuBarExtra shows "Idle" and the waveform symbol.

- [ ] **Step 2: Window open / close lifecycle**

- Menu bar → "Open Window".
- ✅ Window appears titled "Audio Pipeline", sidebar shows "Library / Recordings / Jobs", default selection is Recordings.
- ✅ Dock icon appears.
- Click the window's red close button.
- ✅ Dock icon disappears.
- ⌘N from anywhere with the app frontmost (or menu bar → "Open Window" again).
- ✅ Window reappears, dock icon reappears.

- [ ] **Step 3: Recordings destination**

- ✅ Table populated; existing recordings render the same as before.
- Right-click a recording → ✅ Play / Reveal in Finder / Run Job menu items present.
- Toolbar Refresh button visible and functional.
- No page-footer status rows below the table — status appears in the sidebar bar (next step).

- [ ] **Step 4: Activity bar**

- Menu bar → Start recording, then Stop recording.
- ✅ Sidebar bottom: glass capsule slides up with "Converting recording…".
- ✅ Once conversion completes, "Recording ready" appears briefly, then the capsule slides away ~3 s later.
- Right-click the new recording → Run Job → pick a job.
- ✅ Sidebar bottom: a second glass-capsule row appears with "Running '<job>' on '<rec>'…".
- ✅ When the job completes, the row updates and clears.

- [ ] **Step 5: Spinner alignment under wrap**

- Force a long job/recording name (rename a recording folder, or pick a job whose name overflows).
- ✅ When the activity text wraps to two lines, the spinner stays anchored to the first line, not centred between the two.

- [ ] **Step 6: Jobs destination**

- Sidebar → Jobs.
- ✅ Detail switches to an HSplitView: list on the left (existing jobs), "Select a job" placeholder on the right.
- Toolbar shows + (New Job) and − (Delete).
- ✅ + → a new "Untitled" job appears in the list and is selected; the editor pane is populated with defaults.
- Edit a field → press Save → ✅ list updates with the new name.
- Select a different job → ✅ editor re-seeds with that job's values.
- − → ✅ selected job is removed; editor returns to the placeholder.

- [ ] **Step 7: Settings**

- ⌘, → ✅ Settings opens as its own window, sized roughly 480×260.
- ✅ Only the Recording section is present (no Jobs tab).
- ✅ Location picker and "Keep original .caf" toggle work as before.

- [ ] **Step 8: Final commit / hand-off**

If verification surfaces any defect, fix it as a follow-up commit and re-run the relevant steps. No documentation updates required for this feature.

---

## Self-Review (run after writing)

**1. Spec coverage:**
- ✅ Scene structure (Task 11)
- ✅ Window lifecycle / dock icon (Tasks 8, 9, 10)
- ✅ Opening the window (Tasks 11, 12)
- ✅ Sidebar (Task 10)
- ✅ Sidebar bottom bar (Tasks 7, 13)
- ✅ Recordings destination (Task 6)
- ✅ Jobs destination + JobEditorView changes (Tasks 1, 4, 5)
- ✅ Settings scene (Task 2)
- ✅ MenuBarContent (Task 12)
- ✅ Testing (Task 14 unit, Task 15 manual)
- ✅ Files added / modified / deleted — all 7 added, 7 modified, 1 deleted

**2. Placeholder scan:** all code blocks are concrete; no TBDs.

**3. Type consistency:** `SidebarDestination` cases (`.recordings`, `.jobs`), `Job.makeDraft(presets:)`, `JobEditorView.init(initial:presets:keychain:onSave:)` consistent across tasks.

**4. Decisions documented inline:**
- Spinner anchored via `HStack(alignment: .firstTextBaseline, …)` (Task 7).
- Save semantics: explicit Save button retained (Tasks 4, 5, spec).
- Draft creation at the call site, not in the editor (Task 5).
- Activation policy flipped on delegate-install, not on `becomeMain` (Task 9, with rationale).
