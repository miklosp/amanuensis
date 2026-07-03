# UI Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Dictation config into the main window, add a Mac-privileges section to Settings, redesign Local Models as cards with 2-char language codes, and add non-destructive recording rename.

**Architecture:** Pure UI/navigation changes plus one additive metadata field (`RecordingMetadata.title`) and one additive data field (`LocalModel.supportedLanguages`). No audio/transcription engine behaviour changes. Testable logic (catalog data, metadata/rename) is covered by SPM Swift Testing suites; SwiftUI views are verified by compiling the app target.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing (`import Testing`), local SPM umbrella package `Packages/AudioPipeline`.

## Global Constraints

- Swift 6.2, deployment target macOS 26.3. Default actor isolation is `MainActor` — annotate audio/nonisolated code explicitly (not relevant here; all touched code is UI/MainActor or already-`nonisolated`).
- SPM tests run: `swift test --disable-sandbox --package-path Packages/AudioPipeline` (the `--disable-sandbox` flag is required in this environment). Filter a suite with `--filter <SuiteName>`.
- **After any SPM change goes green, rebuild the app target** to prove the app still compiles: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` (routes `xcodebuild` through the outside-sandbox daemon; `/usr/bin/xcodebuild` self-refuses in-sandbox).
- Rename is **non-destructive**: the on-disk folder name is the recording's identity (`RecordingItem.id`) and is never changed. Rename only writes a display `title` into `meta.json`.
- Language codes are lowercase ISO 639-1 2-char, except SenseVoice's Cantonese `yue` (the sole 3-char code). Whisper's `haw` (Hawaiian) is also 3-char.
- Minimal code, match existing style, touch only what's needed (per CLAUDE.md).

## File Structure

| File | Responsibility | Tasks |
|------|----------------|-------|
| `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift` | Add `supportedLanguages: [String]`; populate 6 catalog entries | 1 |
| `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelLanguagesTests.swift` (new) | Validate language data | 1 |
| `Amanuensis/UI/Models/ModelCardView.swift` (new, replaces `ModelRowView.swift`) | One model as a card with expandable language chips | 2 |
| `Amanuensis/UI/Models/ModelsView.swift` | Card grid layout | 2 |
| `Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift` | Add optional `title` | 3 |
| `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift` | `name` prefers title; add `rename(_:to:)` | 3 |
| `Packages/AudioPipeline/Tests/RecordingStorageTests/Support/Fixtures.swift` | Add `title` to `makeMetadata` | 3 |
| `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingTitleTests.swift` (new) | Title fallback + rename behaviour | 3 |
| `Amanuensis/UI/RecordingsView.swift` | "Rename…" context-menu action + alert | 4 |
| `Amanuensis/UI/Dictation/DictationView.swift` (new) | Dictation controls extracted from Settings | 5 |
| `Amanuensis/UI/MainWindowView.swift` | New `dictation` sidebar destination | 5 |
| `Amanuensis/UI/SettingsView.swift` | Remove Dictation section; add "Mac privileges" section | 5 |
| `Packages/AudioPipeline/Sources/RecordingCore/MicrophonePermission.swift` | Add `isAuthorized()` | 5 |
| `Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift` | Make `isAuthorized()` public | 5 |

**Dependencies / parallelism:** Track A (Tasks 1→2, Local Models), Track B (Tasks 3→4, Rename), and Task 5 (Dictation + Mac privileges) touch **disjoint files** and can be worked in parallel. Within a track the second task depends on the first.

---

### Task 1: `LocalModel.supportedLanguages` data + tests

**Files:**
- Modify: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelLanguagesTests.swift` (new)

**Interfaces:**
- Produces: `LocalModel.supportedLanguages: [String]` (stored, `public let`, lowercase ISO codes). Consumed by Task 2's `ModelCardView`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelLanguagesTests.swift`:

```swift
import Testing
@testable import LocalTranscription

@Suite struct LocalModelLanguagesTests {
    @Test func everyModelHasNonEmptyWellFormedCodes() {
        for model in LocalModelCatalog.all {
            #expect(!model.supportedLanguages.isEmpty, "\(model.id) has no languages")
            for code in model.supportedLanguages {
                #expect(code == code.lowercased(), "\(model.id): \(code) not lowercase")
                #expect(
                    code.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
                    "\(model.id): \(code) is not a 2–3 char code")
            }
            #expect(
                Set(model.supportedLanguages).count == model.supportedLanguages.count,
                "\(model.id) has duplicate codes")
        }
    }

    // For catalog entries whose `languages` summary begins with an integer
    // ("99 languages", "25 European languages", "14 languages (…)"), that
    // number must equal the code count. "50+ (…)" and word summaries
    // ("English", "Japanese", "Multilingual…") have no leading "<n> " and are
    // skipped — this catches summary/list drift without asserting linguistics.
    @Test func summaryCountMatchesListWhenSummaryLeadsWithNumber() {
        for model in LocalModelCatalog.all {
            guard let r = model.languages.range(of: "^\\d+ ", options: .regularExpression)
            else { continue }
            let n = Int(model.languages[r].trimmingCharacters(in: .whitespaces))!
            #expect(
                model.supportedLanguages.count == n,
                "\(model.id): summary says \(n), list has \(model.supportedLanguages.count)")
        }
    }

    @Test func fixedCountsAreExact() {
        #expect(LocalModelCatalog.model(id: "cohere-transcribe")?.supportedLanguages.count == 14)
        #expect(LocalModelCatalog.model(id: "whisper-large-v3-turbo")?.supportedLanguages.count == 99)
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-v3")?.supportedLanguages.count == 25)
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")?.supportedLanguages == ["en"])
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-ja")?.supportedLanguages == ["ja"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelLanguagesTests`
Expected: FAIL to compile — `value of type 'LocalModel' has no member 'supportedLanguages'`.

- [ ] **Step 3: Add the field to the struct**

In `LocalModel.swift`, add to `struct LocalModel` (after `languages`):

```swift
    public let languages: String
    public let supportedLanguages: [String]
```

Add the parameter to the memberwise `public init` — but `LocalModel` uses Swift's synthesized memberwise init only via the struct literal calls; there is no explicit init, so no init edit is needed. (If a compile error says the initializer is ambiguous, it isn't — the six call sites in Step 4 supply the new argument.)

- [ ] **Step 4: Populate all six catalog entries**

Replace the six `LocalModel(...)` literals in `LocalModelCatalog.all` so each gains a `supportedLanguages:` argument (place it right after `languages:`). Full replacement of the array:

```swift
    public static let all: [LocalModel] = [
        LocalModel(id: "parakeet-tdt-ctc-110m", displayName: "Parakeet TDT-CTC 110M",
                   summary: "Tiny and fastest. Best default for English.",
                   languages: "English", supportedLanguages: ["en"],
                   approxBytes: 217 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtCtc110m", recommended: true),
        LocalModel(id: "parakeet-tdt-v3", displayName: "Parakeet TDT v3",
                   summary: "Multilingual, auto-detects language.",
                   languages: "25 European languages",
                   supportedLanguages: [
                       "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
                       "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
                       "sl", "es", "sv", "ru", "uk",
                   ],
                   approxBytes: 460 * MB,
                   runner: .fluidAudioParakeet, selector: "v3", recommended: false),
        LocalModel(id: "cohere-transcribe", displayName: "Cohere Transcribe",
                   summary: "High accuracy. Heavier; transcribes long audio in 35s chunks.",
                   languages: "14 languages (incl. Japanese, Chinese, Korean)",
                   supportedLanguages: [
                       "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar",
                       "ja", "zh", "vi", "ko",
                   ],
                   approxBytes: 2_090 * MB,
                   runner: .fluidAudioCohere, selector: "cohere", recommended: false),
        LocalModel(id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo",
                   summary: "Broad language coverage, near-large-v3 accuracy.",
                   languages: "99 languages",
                   supportedLanguages: [
                       "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
                       "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
                       "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
                       "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
                       "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
                       "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
                       "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
                       "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
                       "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
                       "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su",
                   ],
                   approxBytes: 627 * MB,
                   runner: .whisperKit, selector: "openai_whisper-large-v3-v20240930_626MB", recommended: false),
        LocalModel(id: "parakeet-tdt-ja", displayName: "Parakeet TDT Japanese",
                   summary: "Dedicated Japanese model.",
                   languages: "Japanese", supportedLanguages: ["ja"],
                   approxBytes: 590 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtJa", recommended: false),
        LocalModel(id: "sensevoice-small", displayName: "SenseVoice Small",
                   summary: "Fast multilingual; strong on Chinese.",
                   languages: "50+ (Chinese, Japanese, Korean, English…)",
                   supportedLanguages: ["zh", "yue", "en", "ja", "ko"],
                   approxBytes: 450 * MB,
                   runner: .fluidAudioSenseVoice, selector: "fp16", recommended: false),
    ]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelLanguagesTests`
Expected: PASS (4 tests). Also run the existing catalog suite to confirm no regression: `--filter LocalModelCatalogTests` → PASS.

- [ ] **Step 6: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED (Task 2 hasn't consumed the field yet, but the package must still build the app).

- [ ] **Step 7: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift \
        Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelLanguagesTests.swift
git commit -m "feat(local): add supportedLanguages codes to LocalModel catalog"
```

---

### Task 2: Local Models card grid

**Files:**
- Create: `Amanuensis/UI/Models/ModelCardView.swift`
- Delete: `Amanuensis/UI/Models/ModelRowView.swift`
- Modify: `Amanuensis/UI/Models/ModelsView.swift`

**Interfaces:**
- Consumes: `LocalModel.supportedLanguages` (Task 1); `LocalModelsStore.ModelState` (`isDownloaded`, `isDownloading`, `progress`, `installedBytes`); store flags `dictationModelID`, `residentModelID`, `loadingModelID`, `unloadingModelID`.
- Produces: `ModelCardView` (same init inputs as the former `ModelRowView`).

*View task — verified by compiling the app, not a unit test.*

- [ ] **Step 1: Create `ModelCardView.swift`**

```swift
import SwiftUI
import LocalTranscription

struct ModelCardView: View {
    let model: LocalModel
    let state: LocalModelsStore.ModelState
    let isDictation: Bool
    let isInMemory: Bool
    let isLoading: Bool
    let isUnloading: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var languagesExpanded = false

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var sizeText: String {
        state.isDownloaded ? fmt(state.installedBytes) : "~\(fmt(model.approxBytes))"
    }

    private var canExpandLanguages: Bool { model.supportedLanguages.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(model.summary)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            languagesRow
            if languagesExpanded { languageChips }
            Divider()
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.displayName).font(.headline)
            if model.recommended { badge("Recommended", .tint) }
            if isDictation { badge("Dictation", .tint) }
            if isInMemory { badge("In memory", .green) }
        }
    }

    private func badge(_ text: String, _ fill: some ShapeStyle) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(fill.opacity(0.2), in: Capsule())
    }

    @ViewBuilder private var languagesRow: some View {
        let label = Text("\(sizeText) · \(model.languages)")
            .font(.caption).foregroundStyle(.tertiary)
        if canExpandLanguages {
            Button {
                withAnimation(.snappy) { languagesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(languagesExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var languageChips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 30), spacing: 4)],
            alignment: .leading, spacing: 4
        ) {
            ForEach(model.supportedLanguages, id: \.self) { code in
                Text(code)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            if state.isDownloading {
                ProgressView(value: state.progress).frame(width: 90)
            } else if state.isDownloaded {
                if isLoading || isUnloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(isLoading ? "Loading…" : "Unloading…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .disabled(isLoading || isUnloading)
            } else {
                Button("Download", action: onDownload)
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite `ModelsView.swift` as a grid**

```swift
// ModelsView.swift
import SwiftUI
import LocalTranscription

struct ModelsView: View {
    @Bindable var store: LocalModelsStore

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(LocalModelCatalog.all) { model in
                    ModelCardView(
                        model: model,
                        state: store.states[model.id] ?? .init(),
                        isDictation: model.id == store.dictationModelID,
                        isInMemory: model.id == store.residentModelID,
                        isLoading: model.id == store.loadingModelID,
                        isUnloading: model.id == store.unloadingModelID,
                        onDownload: { Task { await store.download(model) } },
                        onDelete: { Task { await store.delete(model) } })
                }
            }
            .padding(16)
        }
        .task { await store.refresh() }
        .navigationTitle("Local Models")
    }
}
```

- [ ] **Step 3: Delete the old row view**

```bash
git rm Amanuensis/UI/Models/ModelRowView.swift
```

(The synchronized file group auto-drops it; no pbxproj edit needed.)

- [ ] **Step 4: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED, no reference to `ModelRowView` remaining.

- [ ] **Step 5: Manual smoke (note for reviewer)**

Launch the app → sidebar **Local Models** → cards render in a grid; a multi-language model shows a chevron that expands to a wrapped grid of 2-char codes; single-language models (Parakeet 110M/Japanese) show the code inline with no chevron; Download/Delete still work.

- [ ] **Step 6: Commit**

```bash
git add Amanuensis/UI/Models/ModelCardView.swift Amanuensis/UI/Models/ModelsView.swift
git commit -m "feat(ui): Local Models card grid with expandable language codes"
```

---

### Task 3: Recording rename — metadata `title`, `name` fallback, `rename(_:to:)`

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift`
- Modify: `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift`
- Modify: `Packages/AudioPipeline/Tests/RecordingStorageTests/Support/Fixtures.swift`
- Test: `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingTitleTests.swift` (new)

**Interfaces:**
- Produces:
  - `RecordingMetadata.title: String?` (stored `public var`, additive).
  - `RecordingItem.name == (trimmed non-empty title) ?? folderName`; `RecordingItem.id` stays `folderName`.
  - `RecordingsLibrary.rename(_ item: RecordingItem, to newTitle: String) async` — writes/clears `title` in `meta.json`, then `refresh()`.
- Consumed by Task 4's context-menu action.

- [ ] **Step 1: Add `title` param to the test fixture**

In `Fixtures.swift`, add a `title` parameter to `makeMetadata` (place after `notes`) and pass it through:

```swift
func makeMetadata(
    folderName: String = "fixture-folder",
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    stoppedAt: Date? = Date(timeIntervalSince1970: 1_700_000_120),
    durationSeconds: Double? = 120,
    mic: RecordingMetadata.TrackMetadata? = .fixtureMic,
    system: RecordingMetadata.TrackMetadata? = .fixtureSystem,
    hostAppVersion: String? = "test",
    notes: String? = nil,
    title: String? = nil
) -> RecordingMetadata {
    RecordingMetadata(
        folderName: folderName,
        startedAt: startedAt,
        stoppedAt: stoppedAt,
        durationSeconds: durationSeconds,
        mic: mic,
        system: system,
        hostAppVersion: hostAppVersion,
        notes: notes,
        title: title
    )
}
```

- [ ] **Step 2: Write the failing tests**

Create `Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingTitleTests.swift`:

```swift
import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingTitleTests {
    @Test func itemName_prefersTitleOverFolderName() throws {
        try withTempDirectory { baseURL in
            let meta = makeMetadata(folderName: "2026-07-02-1200", title: "Team sync")
            let folderURL = try makeRecordingFolderOnDisk(in: baseURL, name: meta.folderName, metadata: meta)
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.id == "2026-07-02-1200")
            #expect(item.name == "Team sync")
        }
    }

    @Test func itemName_fallsBackToFolderName_whenTitleBlank() throws {
        try withTempDirectory { baseURL in
            let meta = makeMetadata(folderName: "2026-07-02-1200", title: "   ")
            let folderURL = try makeRecordingFolderOnDisk(in: baseURL, name: meta.folderName, metadata: meta)
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.name == "2026-07-02-1200")
        }
    }

    @Test func legacyMetaWithoutTitleKey_stillDecodes() throws {
        try withTempDirectory { baseURL in
            let folderURL = baseURL.appending(path: "legacy", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let json = #"{"schemaVersion":1,"folderName":"legacy","startedAt":"2023-11-14T22:13:20Z"}"#
            try Data(json.utf8).write(
                to: folderURL.appending(path: "meta.json", directoryHint: .notDirectory))
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.name == "legacy")
        }
    }

    @Test func rename_writesTitleAndUpdatesName() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "rec1", metadata: makeMetadata(folderName: "rec1"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let item = try #require(library.recordings.first { $0.id == "rec1" })

            await library.rename(item, to: "My recording")

            #expect(library.recordings.first { $0.id == "rec1" }?.name == "My recording")
            let reread = try #require(RecordingItem(folderURL: item.folderURL))
            #expect(reread.name == "My recording")
        }
    }

    @Test func rename_toBlank_clearsTitleBackToFolderName() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "rec2", metadata: makeMetadata(folderName: "rec2", title: "Old"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let item = try #require(library.recordings.first { $0.id == "rec2" })

            await library.rename(item, to: "   ")

            #expect(library.recordings.first { $0.id == "rec2" }?.name == "rec2")
        }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingTitleTests`
Expected: FAIL to compile — `RecordingMetadata` has no `title`, `RecordingsLibrary` has no `rename`.

- [ ] **Step 4: Add `title` to `RecordingMetadata`**

In `RecordingMetadata.swift`, add the stored property (after `notes`):

```swift
    public var notes: String?
    public var title: String?
```

Add to the `public init` signature (after `notes: String? = nil`) and its body:

```swift
        notes: String? = nil,
        title: String? = nil
    ) {
        // …existing assignments…
        self.notes = notes
        self.title = title
    }
```

(`Codable`/`Equatable` are synthesized in the existing `nonisolated extension`, so `title` is included automatically; a legacy `meta.json` without the key decodes to `nil`.)

- [ ] **Step 5: Make `RecordingItem.name` prefer the title**

In `RecordingsLibrary.swift`, inside `RecordingItem.init?(folderURL:)`, replace the `name = meta.folderName` line (keep `id = meta.folderName`):

```swift
        id = meta.folderName
        if let title = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            name = title
        } else {
            name = meta.folderName
        }
```

- [ ] **Step 6: Add `rename(_:to:)` and a decoder to `RecordingsLibrary`**

Add a decoder (mirrors `RecordingItem.decoder`) and the method to the `RecordingsLibrary` class body:

```swift
    // Renames a recording by writing a display `title` into its meta.json.
    // Non-destructive: the folder (the recording's identity) is untouched.
    // A blank/whitespace title clears it, reverting the name to the folder.
    public func rename(_ item: RecordingItem, to newTitle: String) async {
        let metadataURL = item.folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: metadataURL),
              var meta = try? Self.metadataDecoder.decode(RecordingMetadata.self, from: data) else {
            return
        }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.title = trimmed.isEmpty ? nil : trimmed
        try? meta.write(to: metadataURL)
        await refresh()
    }

    private nonisolated static let metadataDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingTitleTests`
Expected: PASS (5 tests). Then run the full storage suites to confirm no regression:
`swift test --disable-sandbox --package-path Packages/AudioPipeline --filter RecordingMetadataTests` and `--filter RecordingItemTests` and `--filter RecordingsLibraryTests` → all PASS.

- [ ] **Step 8: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift \
        Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift \
        Packages/AudioPipeline/Tests/RecordingStorageTests/Support/Fixtures.swift \
        Packages/AudioPipeline/Tests/RecordingStorageTests/RecordingTitleTests.swift
git commit -m "feat(storage): non-destructive recording rename via meta.json title"
```

---

### Task 4: "Rename…" context-menu action + alert

**Files:**
- Modify: `Amanuensis/UI/RecordingsView.swift`

**Interfaces:**
- Consumes: `RecordingsLibrary.rename(_:to:)` (Task 3), `RecordingItem.name`.

*View task — verified by compiling the app.*

- [ ] **Step 1: Add rename state**

In `RecordingsView`, add next to `pendingDelete`:

```swift
    @State private var pendingDelete: [RecordingItem] = []
    @State private var pendingRename: RecordingItem?
    @State private var renameText: String = ""
```

- [ ] **Step 2: Add the menu button**

In the `.contextMenu(forSelectionType:)` closure, add a "Rename…" button after "Reveal in Finder" (single-item, operates on `first`):

```swift
                Button("Reveal in Finder") { reveal(first) }
                Button("Rename…") {
                    renameText = first.name
                    pendingRename = first
                }
```

- [ ] **Step 3: Add the rename alert**

Add a second `.alert` modifier after the existing delete alert (before `.toolbar`):

```swift
        .alert(
            "Rename recording",
            isPresented: Binding(
                get: { pendingRename != nil },
                set: { if !$0 { pendingRename = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let item = pendingRename else { return }
                let newName = renameText
                pendingRename = nil
                Task { await library.rename(item, to: newName) }
            }
            Button("Cancel", role: .cancel) { pendingRename = nil }
        } message: {
            Text("Enter a display name for this recording. Leave blank to use the original folder name.")
        }
```

- [ ] **Step 4: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke (note for reviewer)**

Right-click a recording → **Rename…** → the field pre-fills the current name → type a new name → Rename → the Name column updates; relaunch the app and the name persists; the folder on disk is unchanged (verify in Finder via Reveal). Rename to blank reverts to the timestamp folder name.

- [ ] **Step 6: Commit**

```bash
git add Amanuensis/UI/RecordingsView.swift
git commit -m "feat(ui): Rename… action in the recordings context menu"
```

---

### Task 5: Dictation → main window + "Mac privileges" Settings section

**Files:**
- Create: `Amanuensis/UI/Dictation/DictationView.swift`
- Modify: `Amanuensis/UI/MainWindowView.swift`
- Modify: `Amanuensis/UI/SettingsView.swift`
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/MicrophonePermission.swift`
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift`

**Interfaces:**
- Consumes: `AppSettings.dictation`, `AppCoordinator` (`allProviders`, `presets`, `localModelsStore`, `dictation.settingsChanged()`, `syncDictationWarmModel()`), `ModelSelector`, `TranscriptionSource`, `Provider.localID`, `TriggerModifier`, `InsertMode`.
- Produces: `SidebarDestination.dictation`; `DictationView(settings:coordinator:)`; `MicrophonePermission.isAuthorized() -> Bool`; public `AudioCapturePermission.isAuthorized()`.

*This task is atomic because both the Dictation extraction (removing its permission rows) and the Mac-privileges section (re-homing them) edit `SettingsView.swift`; splitting them would leave a broken intermediate. View parts are verified by compiling the app.*

- [ ] **Step 1: Expose non-prompting status on both permission helpers**

In `MicrophonePermission.swift`, add:

```swift
    // True when microphone capture is already authorized (never prompts).
    public static func isAuthorized() -> Bool {
        currentStatus() == .authorized
    }
```

In `AudioCapturePermission.swift`, change the existing `isAuthorized()` to `public`:

```swift
    public nonisolated static func isAuthorized() -> Bool {
```

- [ ] **Step 2: Create `DictationView.swift`**

```swift
import AppSettings
import AudioPipelineJobs
import DictationCore
import LocalTranscription
import SwiftUI

struct DictationView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Enable dictation", isOn: $settings.dictation.enabled)
                    .onChange(of: settings.dictation.enabled) { _, _ in
                        coordinator.dictation.settingsChanged()
                    }

                Picker("Trigger key", selection: $settings.dictation.trigger) {
                    ForEach(TriggerModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .onChange(of: settings.dictation.trigger) { _, _ in
                    coordinator.dictation.settingsChanged()
                }
                if settings.dictation.trigger == .function {
                    Text("Fn may also trigger a macOS action (System Settings ▸ Keyboard ▸ “Press 🌐 to”).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Hold threshold") {
                    HStack {
                        Slider(value: holdThresholdBinding, in: 150...600, step: 50)
                        Text("\(settings.dictation.holdThresholdMs) ms")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            Section("Transcription") {
                Picker("Provider", selection: $settings.dictation.providerID) {
                    Text("None").tag(UUID?.none)
                    ForEach(coordinator.allProviders) { provider in
                        Text(provider.name).tag(UUID?.some(provider.id))
                    }
                    if !downloadedLocalIDs.isEmpty {
                        Text("Local").tag(UUID?.some(Provider.localID))
                    }
                }
                .onChange(of: settings.dictation.providerID) { _, _ in
                    Task { await coordinator.syncDictationWarmModel() }
                }

                ModelSelector(
                    isLocal: TranscriptionSource(providerID: settings.dictation.providerID) == .local,
                    model: $settings.dictation.model,
                    downloadedLocalModelIDs: downloadedLocalIDs,
                    suggestedModels: dictationSuggestedModels,
                    isBusy: coordinator.localModelsStore.loadingModelID != nil
                        || coordinator.localModelsStore.unloadingModelID != nil)
                .onChange(of: settings.dictation.model) { _, _ in
                    Task { await coordinator.syncDictationWarmModel() }
                }
            }

            Section {
                Picker("On finish", selection: $settings.dictation.insertMode) {
                    Text("Insert at cursor").tag(InsertMode.autoInsert)
                    Text("Copy to clipboard").tag(InsertMode.clipboardOnly)
                }
                Toggle("Show overlay while dictating", isOn: $settings.dictation.showOverlay)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dictation")
    }

    private var downloadedLocalIDs: [String] {
        LocalModelCatalog.all.map(\.id).filter { coordinator.localModelsStore.states[$0]?.isDownloaded == true }
    }

    private var dictationSuggestedModels: [String] {
        guard case .provider(let id) = TranscriptionSource(providerID: settings.dictation.providerID),
              let provider = coordinator.allProviders.first(where: { $0.id == id }),
              let preset = coordinator.presets.preset(id: provider.presetID) else { return [] }
        return preset.suggestedModels
    }

    private var holdThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.dictation.holdThresholdMs) },
            set: { settings.dictation.holdThresholdMs = Int($0) })
    }
}
```

- [ ] **Step 3: Add the sidebar destination in `MainWindowView.swift`**

Add `dictation` to the enum:

```swift
enum SidebarDestination: Hashable {
    case dictation, recordings, jobs, providers, localModels, logs
}
```

Add a leading sidebar row above the `Section("Library")` (inside the `List`):

```swift
            List(selection: $selection) {
                Label("Dictation", systemImage: "text.bubble")
                    .tag(SidebarDestination.dictation)
                Section("Library") {
                    Label("Recordings", systemImage: "waveform")
                        .tag(SidebarDestination.recordings)
                    // …unchanged…
                }
            }
```

Add the detail case (DictationView supplies its own `navigationTitle`):

```swift
            switch selection {
            case .dictation:
                DictationView(settings: coordinator.settings, coordinator: coordinator)
            case .recordings:
                // …unchanged…
```

- [ ] **Step 4: Rewrite `SettingsView.swift`**

Replace the whole file. Removes the `Section("Dictation")` and its dictation-only helpers (`downloadedLocalIDs`, `dictationSuggestedModels`, `holdThresholdBinding`); adds a leading `Section("Mac privileges")` with four permission rows; keeps Recordings / After-recording / Meetings verbatim. Grant closures request the permission and, for the two truly-async grants (mic, system audio), deep-link to System Settings when the request resolves to *not granted*; Input Monitoring / Accessibility keep the existing behaviour (the OS request itself routes the user to Settings).

```swift
import AppKit
import AppSettings
import RecordingCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator

    @State private var micGranted = MicrophonePermission.isAuthorized()
    @State private var systemAudioGranted = AudioCapturePermission.isAuthorized()
    @State private var inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
    @State private var postEventGranted = TextInserter.hasPostEventAccess()

    var body: some View {
        Form {
            Section("Mac privileges") {
                permissionRow(title: "Microphone", granted: micGranted) {
                    Task {
                        let ok = await MicrophonePermission.requestIfNeeded()
                        if !ok { openPrivacy("Privacy_Microphone") }
                        refreshPermissions()
                    }
                }
                permissionRow(title: "System Audio", granted: systemAudioGranted) {
                    Task {
                        let ok = await AudioCapturePermission.requestIfNeeded()
                        if !ok { openPrivacy("Privacy_ScreenCapture") }
                        refreshPermissions()
                    }
                }
                permissionRow(title: "Input Monitoring (hotkey)", granted: inputMonitoringGranted) {
                    HotkeyTapMonitor.requestInputMonitoringAccess()
                    refreshPermissions()
                }
                permissionRow(title: "Accessibility · post events (auto-insert)", granted: postEventGranted) {
                    TextInserter.requestPostEventAccess()
                    refreshPermissions()
                }
            }
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
            Section("Meetings") {
                Toggle(isOn: $settings.suggestRecordingWhenMicInUse) {
                    VStack(alignment: .leading) {
                        Text("Offer to record when the mic is in use")
                        Text("When another app starts using the microphone (e.g. a meeting), Amanuensis shows a cue to start recording. Watches the default input device only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.suggestRecordingWhenMicInUse) { _, newValue in
                    coordinator.setMicCueEnabled(newValue)
                }
                Toggle(isOn: $settings.suggestStoppingWhenMeetingEnds) {
                    VStack(alignment: .leading) {
                        Text("Offer to stop recording when the meeting ends")
                        Text("While recording, when the app that was using the microphone releases it, Amanuensis shows a cue to stop recording. Watches running processes other than itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.suggestStoppingWhenMeetingEnds) { _, newValue in
                    coordinator.setMicOffCueEnabled(newValue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { refreshPermissions() }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.selectRecordingsFolder(url)
        }
    }

    private func refreshPermissions() {
        micGranted = MicrophonePermission.isAuthorized()
        systemAudioGranted = AudioCapturePermission.isAuthorized()
        inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
        postEventGranted = TextInserter.hasPostEventAccess()
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Grant…", action: grant)
            }
        }
    }
}
```

- [ ] **Step 5: Rebuild the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: BUILD SUCCEEDED. If the build complains that `HotkeyTapMonitor` / `TextInserter` are unresolved, they are app-target types (`Amanuensis/Dictation/`) — no import needed; confirm the symbols are spelled exactly. If `MicrophonePermission` / `AudioCapturePermission` are unresolved, confirm `import RecordingCore` is present.

- [ ] **Step 6: Run the full SPM suite (permission-helper change)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS (the two `isAuthorized()` edits are additive; existing suites unaffected).

- [ ] **Step 7: Manual smoke (note for reviewer)**

- Settings (⌘,) shows **Mac privileges** first with four rows; granted ones show a green check; ungranted show "Grant…". Clicking Grant on an already-denied mic/system-audio opens the matching System Settings pane.
- The Dictation section is gone from Settings.
- Main window sidebar shows **Dictation** above Library; selecting it shows the dictation controls (no permission rows); toggling settings still drives `settingsChanged()` / warm-model sync.

- [ ] **Step 8: Commit**

```bash
git add Amanuensis/UI/Dictation/DictationView.swift Amanuensis/UI/MainWindowView.swift \
        Amanuensis/UI/SettingsView.swift \
        Packages/AudioPipeline/Sources/RecordingCore/MicrophonePermission.swift \
        Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift
git commit -m "feat(ui): Dictation panel in main window; Mac privileges settings section"
```

---

## Final integration pass (after all tasks)

- [ ] Full SPM suite green: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
- [ ] App target builds: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
- [ ] Manual smoke of all four features per the per-task notes above.
- [ ] Then use `superpowers:finishing-a-development-branch` to decide merge/PR.

## Self-Review

**Spec coverage:**
- Component 1 (Dictation → main window, no permission rows) → Task 5 (DictationView + sidebar; permission rows re-homed). ✓
- Component 2 (Mac privileges at top of Settings, all four permissions) → Task 5 (Mac privileges section; `isAuthorized()` exposed). ✓
- Component 3 (cards + language codes) → Tasks 1 (data) + 2 (cards, expandable chips). ✓
- Component 4 (non-destructive rename) → Tasks 3 (metadata/name/rename + tests) + 4 (menu + alert). ✓
- Spec test list (RecordingStorage title/rename/legacy; catalog language format + counts; app build) → Tasks 1, 3 tests + build steps. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows real assertions.

**Type consistency:** `supportedLanguages: [String]` defined in Task 1, consumed in Task 2. `RecordingMetadata.title: String?`, `RecordingsLibrary.rename(_:to:)`, `RecordingItem.name` defined in Task 3, consumed in Task 4. `MicrophonePermission.isAuthorized()` / public `AudioCapturePermission.isAuthorized()` defined and consumed in Task 5. `SidebarDestination.dictation` and `DictationView(settings:coordinator:)` defined and used within Task 5. Names match across tasks.
