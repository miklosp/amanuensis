# Unified app window — design

**Date:** 2026-05-29
**Status:** Draft, awaiting user review
**Scope:** UI restructure — replace the standalone `Window("Recordings")` scene with a single unified window built on `NavigationSplitView`, lift Job CRUD out of Settings, surface in-flight activity in the sidebar.

## Goals

- One window for everything except Settings: sidebar on the left (Recordings, Jobs), content on the right.
- Keep MenuBarExtra exactly as it is — start/stop recording, status line, last-folder shortcuts.
- Move in-flight activity (recording conversion, job runs) out of `RecordingsView`'s footer and into a sidebar bottom bar that collapses when idle.
- Trim Settings to only the Recording preferences. Job CRUD becomes the Jobs sidebar destination.
- Visual language: macOS 26 Liquid Glass via native APIs (`glassEffect`, `GlassEffectContainer`, glass button styles).

## Non-goals

- No per-recording inspector / detail pane (Recordings stays a flat table).
- No job runs / history view.
- No global keyboard shortcut for record start/stop.
- No drag-to-reorder for jobs.
- No persistence of last-selected sidebar destination — opening the window always lands on Recordings.

## Scene structure

`audio_pipelineApp.swift`:

```swift
MenuBarExtra { MenuBarContent(coordinator: coordinator) } label: { … }
    .menuBarExtraStyle(.menu)

Window("Audio Pipeline", id: "main") {
    MainWindowView(coordinator: coordinator)
}
.defaultSize(width: 880, height: 540)
.commands {
    CommandGroup(replacing: .newItem) { OpenMainWindowCommand() }
}

Settings {
    SettingsView(settings: coordinator.settings)
}
```

`Window(id: "main")` replaces today's `Window("Recordings", id: "recordings")`. There is exactly one user-facing window for the app surface; Settings is a separate scene as before.

`OpenMainWindowCommand` is a small `View` that captures `@Environment(\.openWindow)` — necessary because `.commands { … }` runs at scene level and cannot read the environment directly:

```swift
private struct OpenMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Window") { openWindow(id: "main") }
            .keyboardShortcut("n")
    }
}
```

## Window lifecycle / dock icon

- App boots in `.accessory` (no dock icon) — same as today.
- When the main window appears, activation policy flips to `.regular` so a dock icon appears.
- When the main window closes (`windowWillClose`), it flips back to `.accessory`.
- Opening / closing Settings does **not** flip activation policy — Settings opens via `openSettings()` from any state.

Implementation: a small `MainWindowLifecycleDelegate` (NSObject conforming to `NSWindowDelegate`) attached via a `WindowAccessor` (an `NSViewRepresentable` placed in `MainWindowView`'s background that resolves to `view.window`). The delegate chains onto SwiftUI's existing delegate so default behavior is preserved.

Mitigation for known macOS quirks: drive policy flips strictly off `NSWindowDelegate` lifecycle events (`windowDidBecomeMain`, `windowWillClose`), not off SwiftUI `scenePhase`. This avoids dock-icon flicker from spurious phase transitions.

## Opening the window

- MenuBarContent: button labelled "Open Window" (replaces today's "Recordings…") calls `openWindow(id: "main")` + `NSApp.activate()`, then defers a runloop tick to `makeKeyAndOrderFront` (same pattern as today).
- `CommandGroup(replacing: .newItem)` rebinds ⌘N to the same open-window action.
- No dock-click path when window is closed — the app is `.accessory` at that point and has no icon.

## Sidebar

```swift
enum SidebarDestination: Hashable { case recordings, jobs }

NavigationSplitView {
    List(selection: $selection) {
        Section("Library") {
            Label("Recordings", systemImage: "waveform").tag(SidebarDestination.recordings)
            Label("Jobs",       systemImage: "wand.and.stars").tag(SidebarDestination.jobs)
        }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    .safeAreaInset(edge: .bottom) {
        SidebarActivityBar(coordinator: coordinator)
    }
} detail: {
    switch selection {
    case .recordings: RecordingsView(library: coordinator.library, coordinator: coordinator)
                          .navigationTitle("Recordings")
    case .jobs:       JobsView(presets: coordinator.presets,
                               jobs: coordinator.jobs,
                               keychain: coordinator.keychain)
                          .navigationTitle("Jobs")
    }
}
```

- Selection lives on `MainWindowView` as `@State private var selection: SidebarDestination = .recordings`. Not persisted.
- `.listStyle(.sidebar)` provides the standard macOS sidebar background; Liquid Glass selection is system-provided on macOS 26.
- SF Symbols: `waveform` and `wand.and.stars`. Subject to refinement at implementation time.

## Sidebar bottom bar

A dedicated subview that reads `coordinator.recordingActivity` and `coordinator.jobActivity`. Collapses entirely when both are nil:

```swift
struct SidebarActivityBar: View {
    let coordinator: AppCoordinator

    var body: some View {
        if coordinator.recordingActivity == nil && coordinator.jobActivity == nil {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let s = coordinator.recordingActivity { ActivityRow(text: s) }
                if let s = coordinator.jobActivity       { ActivityRow(text: s) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 9))
            .padding(.horizontal, 8).padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct ActivityRow: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).lineLimit(2).truncationMode(.middle)
        }
    }
}
```

Key points:
- `HStack(alignment: .firstTextBaseline, …)` keeps the `ProgressView` aligned with the first text line when the label wraps.
- `EmptyView()` inside `safeAreaInset(edge: .bottom)` collapses the inset cleanly. If verification shows the inset reserves a 0-pt strip with a divider, the conditional moves outside the `safeAreaInset` call instead.
- Single `glassEffect` on the rounded container — no `GlassEffectContainer` needed because we are not stacking multiple glass surfaces here.
- `AppCoordinator` mutations of `recordingActivity` and `jobActivity` are wrapped in `withAnimation { … }` so the bar animates in/out cleanly. No state-machine changes.

`#available(macOS 26, *)` gate: project deployment target is macOS 26.3, so no fallback branch is required.

## Recordings destination

`RecordingsView` is structurally unchanged. Diff vs today:

- Drop the outer `VStack(spacing: 0)` and the two `StatusFooterRow` blocks (status now in the sidebar bar).
- Drop `frame(minWidth: 620, minHeight: 320)` — the parent window enforces minimums.
- Drop the local `StatusFooterRow` type.
- Keep the `Table`, `.contextMenu(forSelectionType:)`, `.alert`, and the existing `.toolbar { Refresh }`.

Toolbar lives in the window's toolbar via `.toolbar { … }` on the destination view. On macOS 26 the toolbar button picks up Liquid Glass automatically.

## Jobs destination — list / editor split

Today's `JobsSettingsPanel` is a list + a sheet (`JobEditorView`) for editing. Lifting to the new destination means:

1. Replace the panel with an `HSplitView` (list on the left, editor on the right).
2. Convert `JobEditorView` from a sheet into an inline editor pane.

### Layout

```swift
struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    let keychain: KeychainStore

    @State private var selection: Job.ID?

    var body: some View {
        HSplitView {
            List(jobs.jobs, selection: $selection) { job in
                Text(job.name).tag(job.id)
            }
            .frame(minWidth: 200, idealWidth: 240)
            .toolbar {
                ToolbarItemGroup {
                    Button { addJob() } label: { Label("New Job", systemImage: "plus") }
                    Button(role: .destructive) { deleteSelected() }
                        label: { Label("Delete", systemImage: "minus") }
                        .disabled(selection == nil)
                }
            }

            if let id = selection, let job = jobs.jobs.first(where: { $0.id == id }) {
                JobEditorView(initial: job,
                              presets: presets,
                              keychain: keychain,
                              onSave: { jobs.upsert($0) })
                    .id(job.id)                                     // re-seed on selection
                    .frame(minWidth: 420)
            } else {
                ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
                    .frame(minWidth: 420)
            }
        }
    }

    private func addJob() {
        let draft = Job.makeDraft(presets: presets)                  // see JobEditorView changes
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

- `HSplitView` is the standard macOS list+editor pattern and works inside `NavigationSplitView`'s detail column. Both panes get explicit minimum widths so the divider does not clip on small windows.
- `Job.ID` selection is local to the destination, not persisted; reopening Jobs starts unselected.
- `.id(job.id)` on `JobEditorView` forces SwiftUI to rebuild it when selection changes, which re-seeds the editor's `@State` from the newly-selected job (today's editor only seeds at init).
- "New Job" creates a draft directly in the store and selects it. There is no separate sheet entry point.

### `JobEditorView` changes

The editor is reused — `JobFieldFormView` and `KeychainAccountPicker` are untouched — but the sheet-specific surface goes away:

- Remove `@Environment(\.dismiss)`.
- Remove the Cancel button and the `dismiss()` call inside `save()`. Save now just calls `onSave(job)`.
- Remove the fixed `.frame(width: 540, height: 560)` — the parent `HSplitView` controls width.
- Lift the "draft constructor" path out of `init`: the current code that synthesises an empty `Untitled` job when `initial == nil` moves to a static `Job.makeDraft(presets:)` factory on `Job`. The editor itself stops accepting `nil`. New-job creation happens at the call site (`addJob()`).
- The existing `name`/`presetID`/etc. `@State` properties stay — combined with `.id(job.id)` on the call site, they correctly re-seed on selection change.

UX note on Save semantics: the editor keeps an explicit **Save** button. The user must press Save (or ⌘S via `.defaultAction`) to commit edits. This preserves today's flow rather than introducing auto-commit-on-change, which would be a separate UX decision.

`JobsSettingsPanel`'s previous "edit" button is no longer needed — selection alone shows the editor.

## Settings scene

`SettingsView` collapses to the Recording preferences only:

```swift
struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Location") { /* same Choose… picker as today */ }
            }
            Section("After recording stops") {
                Toggle(/* keepOriginalCAF — unchanged */)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
    }
}
```

- `TabView` is removed (only one tab remains).
- `presets`, `jobs`, `keychain` parameters are dropped — they are now `JobsView`'s concern.
- Window size tightened from `520×420` to `480×260` to match the lighter content.

## MenuBarContent

Single replacement: the "Recordings…" item becomes "Open Window" pointed at `id: "main"`. Everything else (status line, Start/Stop, Open last/recordings folder, error line, Settings…, Quit) is preserved.

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

## Files touched

### Added

- `audio-pipeline/UI/MainWindowView.swift` — owns `NavigationSplitView`, `SidebarDestination`, sidebar selection state, destination routing.
- `audio-pipeline/UI/Sidebar/SidebarActivityBar.swift` — bottom-bar view with `ActivityRow` and the collapse-when-idle conditional.
- `audio-pipeline/UI/WindowAccessor.swift` — `NSViewRepresentable` resolving to the hosting `NSWindow`.
- `audio-pipeline/UI/MainWindowLifecycleDelegate.swift` — `NSWindowDelegate` that toggles `NSApp.activationPolicy` based on main-window lifecycle, chaining to any pre-existing delegate.
- `audio-pipeline/UI/Jobs/JobsView.swift` — `HSplitView` list+editor for the Jobs destination.

### Modified

- `audio-pipeline/audio_pipelineApp.swift` — `Window("Recordings", id: "recordings")` → `Window("Audio Pipeline", id: "main")`; `SettingsView` args trimmed; `CommandGroup(replacing: .newItem)` added for ⌘N (with `OpenMainWindowCommand` helper view).
- `audio-pipeline/UI/RecordingsView.swift` — drop outer `VStack`, both `StatusFooterRow` blocks, `frame(minWidth:minHeight:)`, the local `StatusFooterRow` type. Keep table, context menu, alert, toolbar.
- `audio-pipeline/UI/SettingsView.swift` — collapse `TabView` to a single inline `Form`; remove `presets`, `jobs`, `keychain` parameters.
- `audio-pipeline/UI/MenuBarContent.swift` — "Recordings…" button → "Open Window" pointed at `id: "main"`.
- `audio-pipeline/UI/Jobs/JobEditorView.swift` — convert from sheet to inline editor: remove `@Environment(\.dismiss)`, remove Cancel button, drop `dismiss()` from `save()`, drop fixed `.frame(width:height:)`, remove the `initial == nil` branch from `init` (callers always pass a real `Job`).
- `Packages/AudioPipeline/Sources/AudioPipelineJobs/Job.swift` — add static `Job.makeDraft(presets: PresetsStore) -> Job` factory containing the `Untitled` defaults logic that today lives inline in `JobEditorView.init`.
- `audio-pipeline/AppCoordinator.swift` — wrap `recordingActivity` / `jobActivity` mutations in `withAnimation { … }`. No state-machine or service changes.

### Deleted

- `audio-pipeline/UI/Jobs/JobsSettingsPanel.swift` — superseded by `JobsView.swift`. Removal is handled automatically by the `PBXFileSystemSynchronizedRootGroup`; no pbxproj edit required.

## Testing

The change is structural/UI; no new logic. Plan:

- **SPM tests:** no changes. `AppSettings`, `RecordingStorage`, `RecordingCore`, `AudioPipelineJobs` test surfaces stay green unchanged.
- **App-hosted XCTest** (one new test in `audio-pipelineTests`): a smoke test that boots the app, opens the main window, asserts the sidebar lists both destinations, and verifies that selecting Jobs swaps the detail content. Runs via the project's `xcode-build` skill (Hammerspoon daemon).
- **Manual verification** per project conventions:
  - Cold launch → no dock icon, MenuBarExtra present.
  - "Open Window" from menu bar → window appears, dock icon appears.
  - Close window → dock icon disappears.
  - Start recording → status line in menu bar (unchanged). On stop, "Converting recording…" shows in the sidebar bottom bar and clears ~3 s after "Recording ready".
  - Run a job on a recording → "Running …" appears in the sidebar bottom bar; clears after completion.
  - Both activities at once → both rows visible; spinner stays aligned to first text line on a wrapping row.
  - Switch sidebar to Jobs → list + editor visible; add, edit, delete a job.
  - ⌘, opens Settings as a separate window with only the recording preferences.

## Risk areas

- **Activation policy flips.** macOS dock-icon updates can flicker if driven too eagerly. Mitigation: drive only from `NSWindowDelegate` lifecycle, not SwiftUI `scenePhase`.
- **`HSplitView` inside `NavigationSplitView` detail.** Works, but the divider can clip if the detail column shrinks below `HSplitView`'s minimums. Mitigation: explicit `frame(minWidth:)` on both panes.
- **`safeAreaInset` collapse.** If `EmptyView()` does not fully collapse the inset (i.e., it reserves a 0-pt strip with a divider), wrap the conditional outside the `safeAreaInset` call instead.

## Out of scope (deferred)

- Recording inspector / detail pane.
- Job run history view.
- Drag-to-reorder for jobs.
- Persisting last-selected sidebar destination across launches.
- Global keyboard shortcut for record start/stop.
