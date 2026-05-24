# SPM Module Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the existing M1 source from the single `audio-pipeline` app target into a local Swift Package Manager umbrella package (`Packages/AudioPipeline/`) with three library modules (`AppSettings`, `RecordingStorage`, `RecordingCore`), so deterministic tests can run via `swift test` and the codebase has clean seams for M2/M3/M4 modules.

**Architecture:** One local SPM package, three library products, app target imports each directly. Each library is its own SPM target with per-target `swiftSettings` (MainActor default for UI-bound modules, nonisolated default for the audio module). App target keeps UI + composition root. Migration runs in three increments (leaves first); each ends with a green build and a commit.

**Tech Stack:** Swift 6.2 (`swift-tools-version: 6.2`, required for `.defaultIsolation`), Xcode 26.5, macOS 26.3 deployment target, Swift Testing for placeholder tests, `xcodeproj` Ruby gem 1.27+ for idempotent project wiring.

**Reference:** Design spec at `docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md`.

---

## File Structure

### Files created

| Path | Purpose |
|---|---|
| `Packages/AudioPipeline/Package.swift` | Umbrella SPM manifest; grows from 1 to 3 library products across tasks 1–3 |
| `Packages/AudioPipeline/Sources/AppSettings/` | Target source dir for `AppSettings` module |
| `Packages/AudioPipeline/Sources/RecordingStorage/` | Target source dir for `RecordingStorage` module |
| `Packages/AudioPipeline/Sources/RecordingCore/` | Target source dir for `RecordingCore` module |
| `Packages/AudioPipeline/Tests/AppSettingsTests/SmokeTests.swift` | Placeholder Swift Testing file verifying target wiring |
| `Packages/AudioPipeline/Tests/RecordingStorageTests/SmokeTests.swift` | Same |
| `Packages/AudioPipeline/Tests/RecordingCoreTests/SmokeTests.swift` | Same |
| `scripts/setup-spm-package.rb` | Idempotent Ruby script: registers local package and links a named product to the app target |
| `scripts/run-setup-spm-package.sh` | Wrapper that installs `xcodeproj` gem on demand and shells through |

### Files moved (`git mv`)

| From | To |
|---|---|
| `audio-pipeline/Settings/AppSettings.swift` | `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift` |
| `audio-pipeline/Storage/RecordingStore.swift` | `Packages/AudioPipeline/Sources/RecordingStorage/RecordingStore.swift` |
| `audio-pipeline/Storage/RecordingMetadata.swift` | `Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift` |
| `audio-pipeline/Storage/RecordingsLibrary.swift` | `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift` |
| `audio-pipeline/Audio/AudioCapturePermission.swift` | `Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift` |
| `audio-pipeline/Audio/AudioFileWriter.swift` | `Packages/AudioPipeline/Sources/RecordingCore/AudioFileWriter.swift` |
| `audio-pipeline/Audio/FLACExporter.swift` | `Packages/AudioPipeline/Sources/RecordingCore/FLACExporter.swift` |
| `audio-pipeline/Audio/MicRecorder.swift` | `Packages/AudioPipeline/Sources/RecordingCore/MicRecorder.swift` |
| `audio-pipeline/Audio/ProcessTapRecorder.swift` | `Packages/AudioPipeline/Sources/RecordingCore/ProcessTapRecorder.swift` |
| `audio-pipeline/Audio/RecordingSession.swift` | `Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift` |

### Files modified (in-place edits)

| Path | Change |
|---|---|
| `audio-pipeline/audio_pipelineApp.swift` | Add `import AppSettings`, `import RecordingStorage` |
| `audio-pipeline/AppCoordinator.swift` | Add three module imports; pass `baseURL:` to `RecordingsLibrary` |
| `audio-pipeline/UI/SettingsView.swift` | Add `import AppSettings` |
| `audio-pipeline/UI/RecordingsView.swift` | Add `import RecordingStorage` |
| `audio-pipeline.xcodeproj/project.pbxproj` | Local package reference + 3 product deps (added via `scripts/setup-spm-package.rb`) |
| `CLAUDE.md` | Update "Tests" and "Project structure quirks" sections to reflect the new layout |

### Files deleted at the end

- Empty directories `audio-pipeline/Audio/`, `audio-pipeline/Storage/`, `audio-pipeline/Settings/`

---

## Task 1: Scaffold the package and migrate `AppSettings`

**Files:**
- Create: `Packages/AudioPipeline/Package.swift`
- Create: `Packages/AudioPipeline/Sources/AppSettings/` (directory)
- Create: `Packages/AudioPipeline/Tests/AppSettingsTests/SmokeTests.swift`
- Create: `scripts/setup-spm-package.rb`
- Create: `scripts/run-setup-spm-package.sh`
- Move: `audio-pipeline/Settings/AppSettings.swift` → `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`
- Modify: `audio-pipeline/audio_pipelineApp.swift`, `audio-pipeline/AppCoordinator.swift`, `audio-pipeline/UI/SettingsView.swift`
- Modify: `audio-pipeline.xcodeproj/project.pbxproj` (via script)

- [ ] **Step 1: Create the package directory tree**

```bash
mkdir -p Packages/AudioPipeline/Sources/AppSettings
mkdir -p Packages/AudioPipeline/Tests/AppSettingsTests
```

- [ ] **Step 2: Write the initial `Package.swift`**

Create `Packages/AudioPipeline/Package.swift` with this exact content:

```swift
// swift-tools-version: 6.2
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS("26.3")],
    products: [
        .library(name: "AppSettings", targets: ["AppSettings"]),
    ],
    targets: [
        .target(name: "AppSettings", swiftSettings: mainActorSettings),
        .testTarget(
            name: "AppSettingsTests",
            dependencies: ["AppSettings"],
            swiftSettings: mainActorSettings
        ),
    ]
)
```

- [ ] **Step 3: Move `AppSettings.swift` into the package**

```bash
git mv audio-pipeline/Settings/AppSettings.swift Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift
```

- [ ] **Step 4: Make `AppSettings` public**

Edit `Packages/AudioPipeline/Sources/AppSettings/AppSettings.swift`. Make the class, the nested enum, the static, the init, and every stored/computed property `public`. The file becomes:

```swift
import Foundation
import Observation

// User preferences, persisted to UserDefaults. MainActor-isolated by the
// module's default actor isolation; observed by the Settings UI.
@Observable
public final class AppSettings {
    public enum OutputFormat: String, CaseIterable, Identifiable {
        case caf
        case flac
        case both

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .caf:  return "Keep raw (.caf)"
            case .flac: return "Convert to FLAC"
            case .both: return "Keep both"
            }
        }
    }

    public var recordingsDirectory: URL {
        didSet {
            defaults.set(recordingsDirectory.path(percentEncoded: false),
                         forKey: Keys.recordingsDirectory)
        }
    }

    public var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public static let defaultRecordingsDirectory: URL = URL.musicDirectory
        .appending(path: "audio-pipeline", directoryHint: .isDirectory)

    public init(defaults: UserDefaults = .standard) {
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

- [ ] **Step 5: Write the placeholder smoke test**

Create `Packages/AudioPipeline/Tests/AppSettingsTests/SmokeTests.swift`:

```swift
import Testing
import AppSettings

// Placeholder test that asserts the AppSettings module compiles into a
// test target. Real tests will replace this per the test-coverage spec
// (docs/superpowers/specs/2026-05-22-test-coverage-design.md).
@Test func outputFormatHasThreeCases() {
    #expect(AppSettings.OutputFormat.allCases.count == 3)
}
```

- [ ] **Step 6: Verify the package builds and tests pass**

Run from the repo root:

```bash
swift test --package-path Packages/AudioPipeline
```

Expected: builds clean, runs 1 test, passes. If `swift` resolves to an Xcode-bundled toolchain that doesn't support Swift 6.2, run:

```bash
xcrun --toolchain swift swift test --package-path Packages/AudioPipeline
```

- [ ] **Step 7: Write `scripts/setup-spm-package.rb`**

Create `scripts/setup-spm-package.rb`:

```ruby
#!/usr/bin/env ruby
# Idempotently:
#   (1) ensures Packages/AudioPipeline is registered as a local SPM package
#       reference on audio-pipeline.xcodeproj;
#   (2) ensures the named library product is linked into the `audio-pipeline`
#       app target's package_product_dependencies and Frameworks build phase.
#
# Usage: ruby scripts/setup-spm-package.rb <ProductName>
# Wrap via scripts/run-setup-spm-package.sh from the repo root.

require 'xcodeproj'

PROJECT_PATH = 'audio-pipeline.xcodeproj'
APP_TARGET   = 'audio-pipeline'
PACKAGE_PATH = 'Packages/AudioPipeline'

product = ARGV.first
raise "usage: setup-spm-package.rb <ProductName>" if product.nil? || product.empty?

project = Xcodeproj::Project.open(PROJECT_PATH)
app = project.targets.find { |t| t.name == APP_TARGET }
raise "app target '#{APP_TARGET}' not found" unless app

# --- (1) Ensure the local package reference exists on the project. ---
package_ref = project.root_object.package_references.find do |ref|
  ref.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    ref.relative_path == PACKAGE_PATH
end

if package_ref.nil?
  package_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  package_ref.relative_path = PACKAGE_PATH
  project.root_object.package_references << package_ref
  puts "added local package reference #{PACKAGE_PATH}"
else
  puts "local package #{PACKAGE_PATH} already registered"
end

# --- (2) Ensure the product is a package_product_dependency of the app ---
# target AND has a PBXBuildFile entry in its Frameworks phase.
existing = app.package_product_dependencies.find { |d| d.product_name == product }
if existing.nil?
  product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product_dep.product_name = product
  app.package_product_dependencies << product_dep

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product_dep
  app.frameworks_build_phase.files << build_file

  puts "linked #{product} to #{APP_TARGET}"
else
  puts "#{product} already linked to #{APP_TARGET}"
end

project.save
puts "saved #{PROJECT_PATH}"
```

- [ ] **Step 8: Write `scripts/run-setup-spm-package.sh`**

Create `scripts/run-setup-spm-package.sh`:

```bash
#!/usr/bin/env bash
# Wrapper for scripts/setup-spm-package.rb that ensures the xcodeproj gem is
# available. Run from the repo root with the product name as an argument:
#
#   scripts/run-setup-spm-package.sh AppSettings
set -euo pipefail

GEM_DIR=/tmp/audio-pipeline-gems

if ! GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby -e 'require "xcodeproj"' 2>/dev/null; then
  echo "installing xcodeproj into $GEM_DIR …"
  gem install --install-dir "$GEM_DIR" --no-document xcodeproj
fi

GEM_HOME="$GEM_DIR" GEM_PATH="$GEM_DIR" ruby scripts/setup-spm-package.rb "$@"
```

Make it executable:

```bash
chmod +x scripts/run-setup-spm-package.sh
```

- [ ] **Step 9: Run the script to wire `AppSettings` into the xcodeproj**

```bash
scripts/run-setup-spm-package.sh AppSettings
```

Expected output (first run):
```
added local package reference Packages/AudioPipeline
linked AppSettings to audio-pipeline
saved audio-pipeline.xcodeproj
```

If re-run, both lines change to "already" — that's the idempotency check.

- [ ] **Step 10: Add `import AppSettings` to the three app-target files that name the type**

Edit `audio-pipeline/audio_pipelineApp.swift`, replace `import SwiftUI` line with:

```swift
import AppSettings
import SwiftUI
```

Edit `audio-pipeline/AppCoordinator.swift`, replace the import block (lines 1-4) with:

```swift
import AppKit
import AppSettings
import Foundation
import Observation
import os
```

Edit `audio-pipeline/UI/SettingsView.swift`, replace the import block (lines 1-2) with:

```swift
import AppKit
import AppSettings
import SwiftUI
```

- [ ] **Step 11: Verify the app target builds**

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox build 2>&1 | tail -20
```

Expected: ends with `** BUILD SUCCEEDED **`. If it fails with "no such module 'AppSettings'", re-check Step 9 ran cleanly and the pbxproj diff includes `XCLocalSwiftPackageReference` and `XCSwiftPackageProductDependency` entries.

- [ ] **Step 12: Commit**

```bash
git add Packages/AudioPipeline/ scripts/setup-spm-package.rb scripts/run-setup-spm-package.sh \
        audio-pipeline.xcodeproj/project.pbxproj \
        audio-pipeline/audio_pipelineApp.swift audio-pipeline/AppCoordinator.swift \
        audio-pipeline/UI/SettingsView.swift
git commit -m "$(cat <<'EOF'
refactor: extract AppSettings into SPM module

First increment of the SPM migration. Creates Packages/AudioPipeline/
with the AppSettings target as the lowest-risk dress rehearsal for the
full pattern. Also adds scripts/setup-spm-package.rb for idempotent
xcodeproj wiring; this script will be reused for the remaining two
modules in subsequent commits.

See docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md
EOF
)"
```

---

## Task 2: Migrate `RecordingStorage` and refactor `RecordingsLibrary.init`

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingStorage/` (directory)
- Create: `Packages/AudioPipeline/Tests/RecordingStorageTests/SmokeTests.swift`
- Modify: `Packages/AudioPipeline/Package.swift` (add second product + targets)
- Move: `audio-pipeline/Storage/{RecordingStore,RecordingMetadata,RecordingsLibrary}.swift` → `Packages/AudioPipeline/Sources/RecordingStorage/`
- Modify (post-move): `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift` (refactor init)
- Modify: `audio-pipeline/AppCoordinator.swift` (import + call-site update)
- Modify: `audio-pipeline/UI/RecordingsView.swift` (import)
- Modify: `audio-pipeline.xcodeproj/project.pbxproj` (via script)

- [ ] **Step 1: Create the source and test directories**

```bash
mkdir -p Packages/AudioPipeline/Sources/RecordingStorage
mkdir -p Packages/AudioPipeline/Tests/RecordingStorageTests
```

- [ ] **Step 2: Update `Package.swift` to add the second library + target**

Replace the contents of `Packages/AudioPipeline/Package.swift` with:

```swift
// swift-tools-version: 6.2
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS("26.3")],
    products: [
        .library(name: "AppSettings",      targets: ["AppSettings"]),
        .library(name: "RecordingStorage", targets: ["RecordingStorage"]),
    ],
    targets: [
        .target(name: "AppSettings",      swiftSettings: mainActorSettings),
        .target(name: "RecordingStorage", swiftSettings: mainActorSettings),
        .testTarget(
            name: "AppSettingsTests",
            dependencies: ["AppSettings"],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "RecordingStorageTests",
            dependencies: ["RecordingStorage"],
            swiftSettings: mainActorSettings
        ),
    ]
)
```

- [ ] **Step 3: Move the three storage files**

```bash
git mv audio-pipeline/Storage/RecordingStore.swift      Packages/AudioPipeline/Sources/RecordingStorage/RecordingStore.swift
git mv audio-pipeline/Storage/RecordingMetadata.swift   Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift
git mv audio-pipeline/Storage/RecordingsLibrary.swift   Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift
```

- [ ] **Step 4: Make `RecordingStore` + `RecordingFolder` public**

Replace the contents of `Packages/AudioPipeline/Sources/RecordingStorage/RecordingStore.swift` with:

```swift
import AppKit
import Foundation
import os

public struct RecordingStore {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func makeRecordingFolder(label: String?, date: Date = Date()) throws -> RecordingFolder {
        let name = Self.folderName(date: date, label: label)
        let folder = baseURL.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return RecordingFolder(url: folder, name: name, startedAt: date)
    }

    public func revealInFinder() {
        try? FileManager.default.createDirectory(
            at: baseURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(baseURL)
    }

    // ISO-8601 with `:` stripped to keep folder names shell-friendly.
    private static func folderName(date: Date, label: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        if let label, !label.isEmpty {
            let safe = label.replacingOccurrences(of: "/", with: "-")
            return "\(stamp)_\(safe)"
        }
        return stamp
    }
}

public struct RecordingFolder: Sendable {
    public let url: URL
    public let name: String
    public let startedAt: Date

    public init(url: URL, name: String, startedAt: Date) {
        self.url = url
        self.name = name
        self.startedAt = startedAt
    }

    public var micURL: URL { url.appending(path: "mic.caf", directoryHint: .notDirectory) }
    public var systemURL: URL { url.appending(path: "system.caf", directoryHint: .notDirectory) }
    public var metadataURL: URL { url.appending(path: "meta.json", directoryHint: .notDirectory) }
}
```

The explicit `RecordingFolder.init` is added because struct memberwise inits default to `internal` even when stored properties are `public`.

- [ ] **Step 5: Make `RecordingMetadata` public**

Replace the contents of `Packages/AudioPipeline/Sources/RecordingStorage/RecordingMetadata.swift` with:

```swift
import Foundation

public struct RecordingMetadata: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var folderName: String
    public var startedAt: Date
    public var stoppedAt: Date?
    public var durationSeconds: Double?
    public var mic: TrackMetadata?
    public var system: TrackMetadata?
    public var hostAppVersion: String?
    public var notes: String?

    public init(
        schemaVersion: Int = 1,
        folderName: String,
        startedAt: Date,
        stoppedAt: Date? = nil,
        durationSeconds: Double? = nil,
        mic: TrackMetadata? = nil,
        system: TrackMetadata? = nil,
        hostAppVersion: String? = nil,
        notes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.folderName = folderName
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.durationSeconds = durationSeconds
        self.mic = mic
        self.system = system
        self.hostAppVersion = hostAppVersion
        self.notes = notes
    }

    public struct TrackMetadata: Codable, Sendable {
        public var fileName: String
        public var sampleRate: Double
        public var channelCount: Int
        public var formatID: String
        public var framesWritten: Int64

        public init(
            fileName: String,
            sampleRate: Double,
            channelCount: Int,
            formatID: String,
            framesWritten: Int64
        ) {
            self.fileName = fileName
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.formatID = formatID
            self.framesWritten = framesWritten
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 6: Refactor `RecordingsLibrary` to take `baseURL: URL` instead of `AppSettings`**

This is the one refactor §3 of the spec called for — keeps `RecordingStorage` from depending on `AppSettings`.

Replace the contents of `Packages/AudioPipeline/Sources/RecordingStorage/RecordingsLibrary.swift` with:

```swift
import Foundation
import Observation

// The model behind the Recordings window. Scans the recordings directory and
// parses each recording's meta.json into a list sorted newest-first.
@Observable
public final class RecordingsLibrary {
    public private(set) var recordings: [RecordingItem] = []

    @ObservationIgnored private let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func refresh() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseURL,
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
    public func delete(_ item: RecordingItem) {
        try? FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
        refresh()
    }
}

public struct RecordingItem: Identifiable {
    public let id: String
    public let name: String
    public let folderURL: URL
    public let startedAt: Date
    public let duration: Double?
    public let sizeBytes: Int64
    public let formatSummary: String

    public init?(folderURL: URL) {
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
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
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

- [ ] **Step 7: Write the placeholder smoke test**

Create `Packages/AudioPipeline/Tests/RecordingStorageTests/SmokeTests.swift`:

```swift
import Foundation
import Testing
import RecordingStorage

// Placeholder test that asserts the RecordingStorage module compiles into a
// test target. Real tests will replace this per the test-coverage spec
// (docs/superpowers/specs/2026-05-22-test-coverage-design.md).
@Test func folderNamingProducesShellFriendlyStamp() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "audio-pipeline-test-\(UUID().uuidString)",
                   directoryHint: .isDirectory)
    let store = RecordingStore(baseURL: tmp)
    let folder = try store.makeRecordingFolder(
        label: nil,
        date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(folder.name.contains(":") == false)
    try? FileManager.default.removeItem(at: tmp)
}
```

- [ ] **Step 8: Verify the package builds and tests pass**

```bash
swift test --package-path Packages/AudioPipeline
```

Expected: 2 tests run (one from each test target), both pass.

- [ ] **Step 9: Wire the new library into the xcodeproj**

```bash
scripts/run-setup-spm-package.sh RecordingStorage
```

Expected output:
```
local package Packages/AudioPipeline already registered
linked RecordingStorage to audio-pipeline
saved audio-pipeline.xcodeproj
```

- [ ] **Step 10: Update `audio-pipeline/AppCoordinator.swift` to use the new RecordingsLibrary init**

Two changes in `audio-pipeline/AppCoordinator.swift`:

a) Add `import RecordingStorage` to the import block (lines 1–5 after Task 1). The block becomes:

```swift
import AppKit
import AppSettings
import Foundation
import Observation
import os
import RecordingStorage
```

b) Update the `init()` method around line 27 to pass the baseURL directly:

```swift
    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = RecordingsLibrary(baseURL: settings.recordingsDirectory)
    }
```

- [ ] **Step 11: Add `import RecordingStorage` to `audio_pipelineApp.swift` and `RecordingsView.swift`**

Edit `audio-pipeline/audio_pipelineApp.swift`. The import block becomes:

```swift
import AppSettings
import RecordingStorage
import SwiftUI
```

Edit `audio-pipeline/UI/RecordingsView.swift`. Replace the import block (lines 1–2) with:

```swift
import AppKit
import RecordingStorage
import SwiftUI
```

- [ ] **Step 12: Verify the app target builds**

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If it fails with "RecordingsLibrary requires a baseURL", confirm Step 10b was applied.

- [ ] **Step 13: Manual smoke**

Launch the built app:

```bash
BUILT=$(xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build -showBuildSettings 2>/dev/null | rg '^\s+BUILT_PRODUCTS_DIR' | awk -F' = ' '{print $2}')
open "$BUILT/audio-pipeline.app"
```

Verify: menu bar icon appears, "Recordings…" menu item opens the Recordings window, the window loads (may be empty if there are no existing recordings — that's fine; the goal is no crash).

- [ ] **Step 14: Commit**

```bash
git add Packages/AudioPipeline/ audio-pipeline.xcodeproj/project.pbxproj \
        audio-pipeline/audio_pipelineApp.swift audio-pipeline/AppCoordinator.swift \
        audio-pipeline/UI/RecordingsView.swift
git commit -m "$(cat <<'EOF'
refactor: extract RecordingStorage into SPM module

Second increment. Moves RecordingStore, RecordingFolder, RecordingMetadata,
RecordingsLibrary, and RecordingItem into the RecordingStorage module.
Refactors RecordingsLibrary.init to take baseURL: URL instead of
AppSettings, so the storage module stays a leaf with no internal
dependencies. AppCoordinator does the wiring.

See docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md
EOF
)"
```

---

## Task 3: Migrate `RecordingCore`

**Files:**
- Create: `Packages/AudioPipeline/Sources/RecordingCore/` (directory)
- Create: `Packages/AudioPipeline/Tests/RecordingCoreTests/SmokeTests.swift`
- Modify: `Packages/AudioPipeline/Package.swift` (add third product + targets, with `RecordingStorage` dep)
- Move: `audio-pipeline/Audio/*.swift` (6 files) → `Packages/AudioPipeline/Sources/RecordingCore/`
- Modify (post-move): make all top-level types `public`; add `import RecordingStorage` to `RecordingSession.swift`
- Modify: `audio-pipeline/AppCoordinator.swift` (import + smoke)
- Modify: `audio-pipeline.xcodeproj/project.pbxproj` (via script)

- [ ] **Step 1: Create the source and test directories**

```bash
mkdir -p Packages/AudioPipeline/Sources/RecordingCore
mkdir -p Packages/AudioPipeline/Tests/RecordingCoreTests
```

- [ ] **Step 2: Update `Package.swift` to add the third library + target**

Replace the contents of `Packages/AudioPipeline/Package.swift` with:

```swift
// swift-tools-version: 6.2
import PackageDescription

let mainActorSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let nonisolatedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "AudioPipeline",
    platforms: [.macOS("26.3")],
    products: [
        .library(name: "AppSettings",      targets: ["AppSettings"]),
        .library(name: "RecordingStorage", targets: ["RecordingStorage"]),
        .library(name: "RecordingCore",    targets: ["RecordingCore"]),
    ],
    targets: [
        .target(name: "AppSettings",      swiftSettings: mainActorSettings),
        .target(name: "RecordingStorage", swiftSettings: mainActorSettings),
        .target(
            name: "RecordingCore",
            dependencies: ["RecordingStorage"],
            swiftSettings: nonisolatedSettings
        ),
        .testTarget(
            name: "AppSettingsTests",
            dependencies: ["AppSettings"],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "RecordingStorageTests",
            dependencies: ["RecordingStorage"],
            swiftSettings: mainActorSettings
        ),
        .testTarget(
            name: "RecordingCoreTests",
            dependencies: ["RecordingCore"],
            swiftSettings: nonisolatedSettings
        ),
    ]
)
```

- [ ] **Step 3: Move the six audio files**

```bash
git mv audio-pipeline/Audio/AudioCapturePermission.swift Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift
git mv audio-pipeline/Audio/AudioFileWriter.swift        Packages/AudioPipeline/Sources/RecordingCore/AudioFileWriter.swift
git mv audio-pipeline/Audio/FLACExporter.swift           Packages/AudioPipeline/Sources/RecordingCore/FLACExporter.swift
git mv audio-pipeline/Audio/MicRecorder.swift            Packages/AudioPipeline/Sources/RecordingCore/MicRecorder.swift
git mv audio-pipeline/Audio/ProcessTapRecorder.swift     Packages/AudioPipeline/Sources/RecordingCore/ProcessTapRecorder.swift
git mv audio-pipeline/Audio/RecordingSession.swift       Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift
```

- [ ] **Step 4: Mark `AudioCapturePermission` public**

Two targeted edits in `Packages/AudioPipeline/Sources/RecordingCore/AudioCapturePermission.swift`:

a) Line 16: change

```swift
enum AudioCapturePermission {
```

to

```swift
public enum AudioCapturePermission {
```

b) Line 57: change

```swift
    nonisolated static func requestIfNeeded() async -> Bool {
```

to

```swift
    public nonisolated static func requestIfNeeded() async -> Bool {
```

`isAuthorized()` and `currentPermissionStatus`-style helpers stay internal — they're not referenced from `AppCoordinator`.

- [ ] **Step 5: Mark `FLACExporter` public**

Two targeted edits in `Packages/AudioPipeline/Sources/RecordingCore/FLACExporter.swift`:

a) Line 7: change

```swift
enum FLACExporter {
```

to

```swift
public enum FLACExporter {
```

b) Line 13: change

```swift
    nonisolated static func export(from source: URL, to destination: URL) async throws {
```

to

```swift
    public nonisolated static func export(from source: URL, to destination: URL) async throws {
```

`ExportError` stays internal — it's only ever caught by `AppCoordinator` as a generic `Error`.

- [ ] **Step 6: Mark `MicRecorder` (class + permission helper) and `RecordingTrackResult` public**

Three targeted edits in `Packages/AudioPipeline/Sources/RecordingCore/MicRecorder.swift`:

a) Line 9: change

```swift
final class MicRecorder {
```

to

```swift
public final class MicRecorder {
```

(The `@MainActor` annotation on line 8 stays.)

b) Line 56: change

```swift
    static func requestPermissionIfNeeded() async -> Bool {
```

to

```swift
    public static func requestPermissionIfNeeded() async -> Bool {
```

c) Line 77: change

```swift
struct RecordingTrackResult: Sendable {
    let url: URL
    let format: AVAudioFormat
    let framesWritten: Int64
}
```

to

```swift
public struct RecordingTrackResult: Sendable {
    public let url: URL
    public let format: AVAudioFormat
    public let framesWritten: Int64
}
```

No explicit `public init` is needed: `RecordingTrackResult` is only constructed inside `RecordingCore` (by `MicRecorder.stop` and `ProcessTapRecorder.stop`); the implicit internal memberwise init is sufficient. External callers only read its properties.

`MicRecorder.init`, `start()`, `stop()` stay internal — only same-module `RecordingSession` calls them.
`MicRecorderError` stays internal — never thrown out of the module's public surface.

- [ ] **Step 7: `ProcessTapRecorder` — no changes**

Verify nothing needs editing:

```bash
rg -n 'ProcessTapRecorder|ProcessTapError' audio-pipeline/
```

Expected: zero matches in `audio-pipeline/` (only `Packages/AudioPipeline/Sources/RecordingCore/` contains references). Both `ProcessTapRecorder` and `ProcessTapError` are used only from `RecordingSession` (same module). Leave them `internal`. Skip to Step 8.

- [ ] **Step 8: Add `import RecordingStorage` and mark `RecordingSession` public**

Four targeted edits in `Packages/AudioPipeline/Sources/RecordingCore/RecordingSession.swift`:

a) Lines 1–3 (import block): change

```swift
import AVFoundation
import Foundation
import os
```

to

```swift
import AVFoundation
import Foundation
import os
import RecordingStorage
```

b) Line 9: change

```swift
final class RecordingSession {
```

to

```swift
public final class RecordingSession {
```

(The `@MainActor` annotation on line 8 stays.)

c) Lines 10 and 15: mark `folder` and `init(folder:)` public:

Change line 10 from

```swift
    let folder: RecordingFolder
```

to

```swift
    public let folder: RecordingFolder
```

Change line 15 from

```swift
    init(folder: RecordingFolder) throws {
```

to

```swift
    public init(folder: RecordingFolder) throws {
```

d) Lines 21, 38–41, and 43: mark `start()`, `StopResult`, and `stop()` public:

Change line 21 from

```swift
    func start() throws {
```

to

```swift
    public func start() throws {
```

Change lines 38–41 from

```swift
    struct StopResult: Sendable {
        let mic: RecordingTrackResult
        let system: RecordingTrackResult?
    }
```

to

```swift
    public struct StopResult: Sendable {
        public let mic: RecordingTrackResult
        public let system: RecordingTrackResult?
    }
```

Change line 43 from

```swift
    func stop() -> StopResult {
```

to

```swift
    public func stop() -> StopResult {
```

Like `RecordingTrackResult`, `StopResult` is only constructed inside the module (in `stop()`) — the implicit internal memberwise init is fine; external callers only read `.mic` and `.system`.

- [ ] **Step 9: `AudioFileWriter` — no changes**

Verify it's internal-only:

```bash
rg -n 'AudioFileWriter' audio-pipeline/
```

Expected: zero matches in `audio-pipeline/`. `AudioFileWriter` is only used by `MicRecorder` and `ProcessTapRecorder` (same module). Leave it `internal`.

- [ ] **Step 10: Write the placeholder smoke test**

Create `Packages/AudioPipeline/Tests/RecordingCoreTests/SmokeTests.swift`:

```swift
import Testing
import RecordingCore

// Placeholder test that asserts the RecordingCore module compiles into a
// test target. Real tests (RecorderStateMachine, OutputConversionPlanner,
// FLACExporter against fixture CAF) will replace this per the
// test-coverage spec
// (docs/superpowers/specs/2026-05-22-test-coverage-design.md).
@Test func moduleImports() {
    #expect(Bool(true))
}
```

- [ ] **Step 11: Verify the package builds and tests pass**

```bash
swift test --package-path Packages/AudioPipeline
```

Expected: 3 tests across 3 test targets, all pass.

If `RecordingCore` fails to build with concurrency errors (e.g., "main actor-isolated property cannot be referenced from a nonisolated context"), audit any `public` additions on `@MainActor`-annotated types — the explicit `@MainActor` annotation overrides the module's nonisolated default and remains correct; do not remove it.

- [ ] **Step 12: Wire the new library into the xcodeproj**

```bash
scripts/run-setup-spm-package.sh RecordingCore
```

Expected:
```
local package Packages/AudioPipeline already registered
linked RecordingCore to audio-pipeline
saved audio-pipeline.xcodeproj
```

- [ ] **Step 13: Add `import RecordingCore` to `AppCoordinator.swift`**

Edit `audio-pipeline/AppCoordinator.swift`. The import block becomes:

```swift
import AppKit
import AppSettings
import Foundation
import Observation
import os
import RecordingCore
import RecordingStorage
```

- [ ] **Step 14: Verify the app target builds**

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If it fails with "X is inaccessible due to internal protection level", a type used from `AppCoordinator` was not marked `public` in Steps 4–9. Common omissions: the `RecordingSession.stop()` return type and its nested `mic` / `system` properties; the `RecordingTrackResult.framesWritten` property.

- [ ] **Step 15: Manual end-to-end smoke**

Launch the built app and run one full recording cycle:

```bash
BUILT=$(xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build -showBuildSettings 2>/dev/null | rg '^\s+BUILT_PRODUCTS_DIR' | awk -F' = ' '{print $2}')
open "$BUILT/audio-pipeline.app"
```

Manually: click the menu bar icon → "Start recording" → wait 5 seconds → "Stop recording" → "Open last recording folder". Expected: `mic.caf` and `system.caf` (and `mic.flac`/`system.flac` if the default output format is FLAC) exist in the folder. No crash, no error in the menu UI.

- [ ] **Step 16: Commit**

```bash
git add Packages/AudioPipeline/ audio-pipeline.xcodeproj/project.pbxproj \
        audio-pipeline/AppCoordinator.swift
git commit -m "$(cat <<'EOF'
refactor: extract RecordingCore into SPM module

Third increment. Moves the six audio files (AudioCapturePermission,
AudioFileWriter, FLACExporter, MicRecorder, ProcessTapRecorder,
RecordingSession) into the RecordingCore module. The module's default
isolation stays nonisolated so Core Audio IOProc callbacks compile;
explicit @MainActor on the lifecycle types is preserved.

App target now imports all three modules. Migration of M1 source from
the app target into Packages/AudioPipeline/ is complete; the cleanup
of empty subfolders follows in the next commit.

See docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md
EOF
)"
```

---

## Task 4: Cleanup and documentation

**Files:**
- Delete: `audio-pipeline/Audio/`, `audio-pipeline/Storage/`, `audio-pipeline/Settings/` (now empty)
- Modify: `CLAUDE.md`

- [ ] **Step 1: Verify the three subfolders are empty**

```bash
ls -A audio-pipeline/Audio audio-pipeline/Storage audio-pipeline/Settings 2>&1
```

Expected: each lists nothing (or fails with "No such file or directory" if the folder was already empty and removed by `git mv` of its last file). If any file remains, stop and resolve it before deleting the directory.

- [ ] **Step 2: Remove the empty directories**

```bash
rmdir audio-pipeline/Audio audio-pipeline/Storage audio-pipeline/Settings 2>/dev/null || true
```

The `|| true` covers the case where `git mv` already removed an empty parent. The `PBXFileSystemSynchronizedRootGroup` automatically stops tracking gone directories — no `pbxproj` edit needed.

- [ ] **Step 3: Verify the app still builds**

```bash
xcodebuild -project audio-pipeline.xcodeproj -scheme audio-pipeline -configuration Debug -derivedDataPath /tmp/audio-pipeline-build OTHER_SWIFT_FLAGS=-disable-sandbox build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Update `CLAUDE.md`**

Two edits to `CLAUDE.md`:

a) Update the "Project" section paragraph to reflect that M1 source now lives in `Packages/AudioPipeline/` rather than in the app target's source folder. Replace the existing paragraph that begins with "macOS SwiftUI app, freshly scaffolded..." with:

```markdown
macOS SwiftUI app. Bundle identifier `work.miklos.audio-pipeline`, deployment target macOS 26.3, Swift 6.2. M1 (menu-bar recorder, mic + system audio capture via Core Audio process tap, FLAC conversion) is complete. Source for the audio + storage + settings layers lives in a local SPM umbrella package at `Packages/AudioPipeline/`; the app target keeps UI, the app entry point, and `AppCoordinator` as the composition root.
```

b) Update the "Tests" section. Replace its contents with:

```markdown
Two test surfaces:

- **SPM tests** (autonomous, run via `swift test --package-path Packages/AudioPipeline`): deterministic logic in `AppSettingsTests`, `RecordingStorageTests`, `RecordingCoreTests`. These run inside the Claude Code sandbox without flags.
- **App-hosted XCTest** (`audio-pipelineTests` target, Xcode-scoped): integration smoke for code that needs a real audio device, the TCC private SPI, or a running `NSApp`. Run from Xcode (⌘U) or `xcodebuild test`. The latter currently hits the codesign-in-nested-sandbox blocker described in `~/.claude/projects/-Users-miklos-Code-audio-pipeline/memory/project_xcodebuild_test_sandbox.md`.

The SPM scaffolding script for adding new library products is `scripts/run-setup-spm-package.sh <ProductName>`.
```

c) Update the "Project structure quirks" section's `PBXFileSystemSynchronizedRootGroup` bullet. Append a sentence to it:

```markdown
The synchronized group's folder (`audio-pipeline/`) and the package source folders (`Packages/AudioPipeline/Sources/`) deliberately do not overlap — see `docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md` §4.
```

- [ ] **Step 5: Commit**

```bash
git add audio-pipeline/ CLAUDE.md
git commit -m "$(cat <<'EOF'
chore: remove empty M1 source dirs and update CLAUDE.md

Concludes the SPM migration. The empty audio-pipeline/{Audio,Storage,
Settings}/ subdirectories are removed; CLAUDE.md is updated to reflect
the new package layout, the dual SPM/Xcode test surfaces, and the
synchronized-group ↔ package-folder boundary.

See docs/superpowers/specs/2026-05-24-spm-module-architecture-design.md
EOF
)"
```
