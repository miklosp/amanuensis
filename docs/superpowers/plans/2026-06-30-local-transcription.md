# Local (on-device) transcription — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add on-device transcription to Amanuensis — a Models page (download / delete / size / languages) over WhisperKit + FluidAudio, plus end-to-end batch transcription of a recording through the existing Jobs pipeline.

**Architecture:** A new SPM module `LocalTranscription` wraps WhisperKit + FluidAudio behind a `LocalTranscriptionEngine` protocol (one adapter per package), routed by a `LocalTranscriptionService` actor. A `@MainActor @Observable LocalModelsStore` drives the Models-page UI. Batch transcription plugs into the existing `AudioJobSending` seam via a new `localTranscription` `JobShape` and a keyless "On-device" provider; the handler is injected into `JobRunner` by `AppCoordinator`. Pure logic (catalog, storage, routing, store, handler, shape/runner changes) is TDD'd against fakes; the real package adapters, UI, and end-to-end transcription are device-verified.

**Tech Stack:** Swift 6.2, SwiftUI, Core ML / ANE, WhisperKit (`argmaxinc/WhisperKit`), FluidAudio (`FluidInference/FluidAudio`), Swift Testing.

## Global Constraints

- **Deployment target macOS 26.3; Swift 6.2.** App Sandbox ON; `com.apple.security.network.client` already present (covers HF downloads) — **no new entitlement**.
- **Models live in Application Support** (`~/Library/Application Support/Amanuensis/Models/`), inside the app container. WhisperKit defaults to `~/Documents/huggingface/…` — **must override `downloadBase`**.
- **Default actor isolation is `MainActor`.** The `LocalTranscription` module uses `nonisolatedSettings` (like `AudioPipelineJobs`). Inference must run off-main: FluidAudio `AsrManager` is an `actor`; the service is an `actor`; the store is `@MainActor @Observable`. Never rely on a bare `nonisolated async` to leave the main actor.
- **FluidAudio docs are stale** — `transcribe` requires `decoderState: inout TdtDecoderState`. Use the signatures in `docs/local-transcription-api-reference.md` (the authoritative API reference for this plan).
- **Module naming:** new product/module is `LocalTranscription` (`import LocalTranscription`). New `.swift` files under `Amanuensis/` are auto-registered (synchronized group). SPM scaffolding via `scripts/run-setup-spm-package.sh LocalTranscription`.
- **Tests:** Swift Testing (`import Testing`, `@Test`, `#expect`). SPM suite must stay autonomous (`swift test --disable-sandbox --package-path Packages/AudioPipeline`). After SPM tests pass, **rebuild the app target** (`./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`).
- **Stable model IDs** (used as `job.model`, `suggestedModels`, catalog keys): `parakeet-tdt-ctc-110m`, `parakeet-tdt-v3`, `cohere-transcribe`, `whisper-large-v3-turbo`, `parakeet-tdt-ja`, `sensevoice-small`.

---

## File Structure

**New module — `Packages/AudioPipeline/Sources/LocalTranscription/`**
- `LocalModel.swift` — `LocalModel`, `LocalRunner`, `LocalModelCatalog` (the six models).
- `ModelStorage.swift` — Application Support base dir + recursive folder-size.
- `LocalTranscriptionEngine.swift` — engine protocol + `LocalTranscriptionError`.
- `FluidAudioEngine.swift` — adapter for Parakeet (110m/v3/ja), SenseVoice, Cohere.
- `WhisperKitEngine.swift` — adapter for Whisper large-v3-turbo.
- `LocalTranscriptionService.swift` — `actor` routing modelID → engine; model-management passthrough.
- `LocalModelsStore.swift` — `@MainActor @Observable` UI store.
- `LocalTranscriptionSender.swift` — `AudioJobSending` handler (depends on `AudioPipelineJobs`).

**New tests — `Packages/AudioPipeline/Tests/LocalTranscriptionTests/`**
- `LocalModelCatalogTests.swift`, `ModelStorageTests.swift`, `LocalTranscriptionServiceTests.swift`, `LocalModelsStoreTests.swift`, `LocalTranscriptionSenderTests.swift`, plus a shared `FakeEngine.swift`.

**Modified — `Packages/AudioPipeline/Sources/AudioPipelineJobs/`**
- `JobShape.swift` — add `.localTranscription` + `requiresAPIKey`.
- `FieldSpec.swift` — fields for the new shape.
- `JobRunner.swift` — skip key fetch when `!shape.requiresAPIKey`.
- `Resources/presets.json` — `on-device` preset.

**Modified — `Amanuensis/`**
- `UI/Models/ModelsView.swift`, `UI/Models/ModelRowView.swift` — the page (new files).
- `UI/SettingsView.swift` — surface the Models page.
- `UI/Providers/ProviderEditorView.swift` — relax API-key requirement for keyless shapes.
- `AppCoordinator.swift` — build `LocalTranscriptionService`, inject `LocalTranscriptionSender` into `JobRunner`.

**Modified — `Packages/AudioPipeline/Package.swift`** — add WhisperKit + FluidAudio deps + `LocalTranscription` product/target/test target; add the module to `nonisolatedSettings`.

---

## Phase A — Module & dependencies

### Task 1: Scaffold `LocalTranscription` module + add package dependencies

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/Placeholder.swift`
- Modify: `Packages/AudioPipeline/Package.swift`

**Interfaces:**
- Produces: an importable `LocalTranscription` module (empty) linking `WhisperKit` + `FluidAudio`.

- [ ] **Step 1: Scaffold the product**

Run: `./scripts/run-setup-spm-package.sh LocalTranscription`
Expected: creates `Sources/LocalTranscription/` + `Tests/LocalTranscriptionTests/` and a product/target in `Package.swift`.

- [ ] **Step 2: Add the external dependencies in `Package.swift`**

In the `dependencies:` array (verify latest tags at add-time — see `docs/local-transcription-api-reference.md` §D):

```swift
.package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
.package(url: "https://github.com/FluidInference/FluidAudio", from: "0.12.0"),
```

On the `LocalTranscription` target, add product deps and nonisolated settings:

```swift
.target(
    name: "LocalTranscription",
    dependencies: [
        "AudioPipelineJobs", "AppLog",
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "FluidAudio", package: "FluidAudio"),
    ],
    swiftSettings: nonisolatedSettings
),
```

- [ ] **Step 3: Minimal placeholder so the target compiles**

```swift
// Sources/LocalTranscription/Placeholder.swift
import WhisperKit
import FluidAudio

enum LocalTranscriptionModule {}
```

- [ ] **Step 4: Resolve + build**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: dependencies resolve and the module compiles. (First resolve fetches WhisperKit, FluidAudio, swift-transformers, etc.)

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Package.swift Packages/AudioPipeline/Sources/LocalTranscription
git commit -m "feat(local): scaffold LocalTranscription module with WhisperKit + FluidAudio deps"
```

---

## Phase B — Catalog & storage (TDD)

### Task 2: `LocalModel` + `LocalModelCatalog`

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelCatalogTests.swift`

**Interfaces:**
- Produces: `LocalRunner` enum; `LocalModel` struct (`id, displayName, summary, languages, approxBytes, runner, selector, recommended`); `LocalModelCatalog.all: [LocalModel]`, `LocalModelCatalog.model(id:) -> LocalModel?`.

- [ ] **Step 1: Write the failing test**

```swift
// LocalModelCatalogTests.swift
import Testing
@testable import LocalTranscription

@Test func catalogHasSixModelsWithUniqueIDs() {
    let all = LocalModelCatalog.all
    #expect(all.count == 6)
    #expect(Set(all.map(\.id)).count == 6)
}

@Test func recommendedModelIsParakeet110m() {
    let rec = LocalModelCatalog.all.filter(\.recommended)
    #expect(rec.count == 1)
    #expect(rec.first?.id == "parakeet-tdt-ctc-110m")
}

@Test func lookupResolvesWhisperTurboToWhisperKit() {
    let m = LocalModelCatalog.model(id: "whisper-large-v3-turbo")
    #expect(m?.runner == .whisperKit)
    #expect(m?.selector == "openai_whisper-large-v3-v20240930_626MB")
}

@Test func cohereIsFluidAudioCohereRunner() {
    #expect(LocalModelCatalog.model(id: "cohere-transcribe")?.runner == .fluidAudioCohere)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelCatalogTests`
Expected: FAIL — `LocalModelCatalog` / `LocalModel` undefined.

- [ ] **Step 3: Implement**

```swift
// LocalModel.swift
import Foundation

public enum LocalRunner: String, Codable, Sendable, Hashable {
    case fluidAudioParakeet      // AsrManager, version selector
    case fluidAudioSenseVoice    // SenseVoiceManager
    case fluidAudioCohere        // CoherePipeline
    case whisperKit              // WhisperKit
}

public struct LocalModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let languages: String
    public let approxBytes: Int64
    public let runner: LocalRunner
    public let selector: String   // version case name or WhisperKit variant id
    public let recommended: Bool
}

public enum LocalModelCatalog {
    private static let MB: Int64 = 1_000_000
    public static let all: [LocalModel] = [
        LocalModel(id: "parakeet-tdt-ctc-110m", displayName: "Parakeet TDT-CTC 110M",
                   summary: "Tiny and fastest. Best default for English.",
                   languages: "English", approxBytes: 217 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtCtc110m", recommended: true),
        LocalModel(id: "parakeet-tdt-v3", displayName: "Parakeet TDT v3",
                   summary: "Multilingual, auto-detects language.",
                   languages: "25 European languages", approxBytes: 460 * MB,
                   runner: .fluidAudioParakeet, selector: "v3", recommended: false),
        LocalModel(id: "cohere-transcribe", displayName: "Cohere Transcribe",
                   summary: "High accuracy. Heavier; transcribes long audio in 35s chunks.",
                   languages: "14 languages (incl. Japanese, Chinese, Korean)", approxBytes: 2_090 * MB,
                   runner: .fluidAudioCohere, selector: "cohere", recommended: false),
        LocalModel(id: "whisper-large-v3-turbo", displayName: "Whisper large-v3-turbo",
                   summary: "Broad language coverage, near-large-v3 accuracy.",
                   languages: "99 languages", approxBytes: 627 * MB,
                   runner: .whisperKit, selector: "openai_whisper-large-v3-v20240930_626MB", recommended: false),
        LocalModel(id: "parakeet-tdt-ja", displayName: "Parakeet TDT Japanese",
                   summary: "Dedicated Japanese model.",
                   languages: "Japanese", approxBytes: 590 * MB,
                   runner: .fluidAudioParakeet, selector: "tdtJa", recommended: false),
        LocalModel(id: "sensevoice-small", displayName: "SenseVoice Small",
                   summary: "Fast multilingual; strong on Chinese.",
                   languages: "50+ (Chinese, Japanese, Korean, English…)", approxBytes: 450 * MB,
                   runner: .fluidAudioSenseVoice, selector: "fp16", recommended: false),
    ]
    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelCatalogTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalModel.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelCatalogTests.swift
git commit -m "feat(local): model catalog for the six v1 on-device models"
```

### Task 3: `ModelStorage` — Application Support base + folder-size

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/ModelStorage.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/ModelStorageTests.swift`

**Interfaces:**
- Produces: `ModelStorage.base() throws -> URL` (creates `…/Application Support/Amanuensis/Models/`), `ModelStorage.runnerDir(_:) throws -> URL`, `ModelStorage.directorySize(_:) -> Int64`.

- [ ] **Step 1: Write the failing test**

```swift
// ModelStorageTests.swift
import Foundation
import Testing
@testable import LocalTranscription

@Test func directorySizeSumsFilesRecursively() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let sub = tmp.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data(count: 1000).write(to: tmp.appendingPathComponent("root.bin"))
    try Data(count: 2000).write(to: sub.appendingPathComponent("leaf.bin"))
    defer { try? FileManager.default.removeItem(at: tmp) }
    #expect(ModelStorage.directorySize(tmp) == 3000)
}

@Test func directorySizeIsZeroForMissingDir() {
    #expect(ModelStorage.directorySize(URL(fileURLWithPath: "/no/such/dir/\(UUID())")) == 0)
}

@Test func runnerDirIsUnderBase() throws {
    let dir = try ModelStorage.runnerDir(.whisperKit)
    #expect(dir.path.contains("Amanuensis/Models"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ModelStorageTests`
Expected: FAIL — `ModelStorage` undefined.

- [ ] **Step 3: Implement**

```swift
// ModelStorage.swift
import Foundation

public enum ModelStorage {
    public static func base() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Amanuensis/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func runnerDir(_ runner: LocalRunner) throws -> URL {
        let dir = try base().appendingPathComponent(runner.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url,
              includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter ModelStorageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/ModelStorage.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/ModelStorageTests.swift
git commit -m "feat(local): model storage paths + recursive folder size"
```

---

## Phase C — Engine protocol, service, store (TDD with fakes)

### Task 4: `LocalTranscriptionEngine` protocol + errors + `FakeEngine`

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/FakeEngine.swift`

**Interfaces:**
- Produces: `protocol LocalTranscriptionEngine: Sendable` with `isDownloaded(_:) async -> Bool`, `installedBytes(_:) async -> Int64`, `download(_:progress:) async throws`, `delete(_:) async throws`, `transcribe(audioURL:model:language:) async throws -> String`; `enum LocalTranscriptionError: LocalizedError`.

- [ ] **Step 1: Write the protocol + errors**

```swift
// LocalTranscriptionEngine.swift
import Foundation

public protocol LocalTranscriptionEngine: Sendable {
    func isDownloaded(_ model: LocalModel) async -> Bool
    func installedBytes(_ model: LocalModel) async -> Int64
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws
    func delete(_ model: LocalModel) async throws
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String
}

public enum LocalTranscriptionError: LocalizedError {
    case unsupportedModel(String)
    case modelNotDownloaded(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let id):  return "Unknown on-device model “\(id)”."
        case .modelNotDownloaded(let n): return "The on-device model “\(n)” is not downloaded. Download it in Settings → Models."
        case .transcriptionFailed(let m): return "On-device transcription failed: \(m)"
        }
    }
}
```

- [ ] **Step 2: Write a reusable `FakeEngine` for tests**

```swift
// FakeEngine.swift  (test target)
import Foundation
@testable import LocalTranscription

actor FakeEngine: LocalTranscriptionEngine {
    var downloaded: Set<String> = []
    var transcript = "fake transcript"
    var lastTranscribedModel: String?

    func isDownloaded(_ model: LocalModel) async -> Bool { downloaded.contains(model.id) }
    func installedBytes(_ model: LocalModel) async -> Int64 { downloaded.contains(model.id) ? 123 : 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.5); progress(1.0); downloaded.insert(model.id)
    }
    func delete(_ model: LocalModel) async throws { downloaded.remove(model.id) }
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard downloaded.contains(model.id) else { throw LocalTranscriptionError.modelNotDownloaded(model.displayName) }
        lastTranscribedModel = model.id
        return transcript
    }
}
```

- [ ] **Step 3: Build the test target**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline --target LocalTranscriptionTests`
Expected: compiles (no assertions yet — exercised in Task 5).

- [ ] **Step 4: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionEngine.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/FakeEngine.swift
git commit -m "feat(local): engine protocol, error type, and test fake"
```

### Task 5: `LocalTranscriptionService` — route modelID → engine

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalTranscriptionServiceTests.swift`

**Interfaces:**
- Consumes: `LocalTranscriptionEngine`, `LocalModelCatalog`.
- Produces: `actor LocalTranscriptionService` with `init(fluidAudio:whisperKit:)` (each `any LocalTranscriptionEngine`) and methods keyed by model id: `transcribe(audioURL:modelID:language:) async throws -> String`, `isDownloaded(modelID:) async -> Bool`, `installedBytes(modelID:) async -> Int64`, `download(modelID:progress:) async throws`, `delete(modelID:) async throws`.

- [ ] **Step 1: Write the failing test**

```swift
// LocalTranscriptionServiceTests.swift
import Foundation
import Testing
@testable import LocalTranscription

private func makeService() -> (LocalTranscriptionService, FakeEngine, FakeEngine) {
    let fa = FakeEngine(); let wk = FakeEngine()
    return (LocalTranscriptionService(fluidAudio: fa, whisperKit: wk), fa, wk)
}

@Test func routesWhisperModelToWhisperEngine() async throws {
    let (svc, fa, wk) = makeService()
    try await svc.download(modelID: "whisper-large-v3-turbo") { _ in }
    _ = try await svc.transcribe(audioURL: URL(fileURLWithPath: "/x.flac"), modelID: "whisper-large-v3-turbo", language: nil)
    #expect(await wk.lastTranscribedModel == "whisper-large-v3-turbo")
    #expect(await fa.lastTranscribedModel == nil)
}

@Test func routesParakeetToFluidAudioEngine() async throws {
    let (svc, fa, _) = makeService()
    try await svc.download(modelID: "parakeet-tdt-ctc-110m") { _ in }
    _ = try await svc.transcribe(audioURL: URL(fileURLWithPath: "/x.flac"), modelID: "parakeet-tdt-ctc-110m", language: nil)
    #expect(await fa.lastTranscribedModel == "parakeet-tdt-ctc-110m")
}

@Test func unknownModelThrows() async {
    let (svc, _, _) = makeService()
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await svc.transcribe(audioURL: URL(fileURLWithPath: "/x"), modelID: "nope", language: nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalTranscriptionServiceTests`
Expected: FAIL — `LocalTranscriptionService` undefined.

- [ ] **Step 3: Implement**

```swift
// LocalTranscriptionService.swift
import Foundation

public actor LocalTranscriptionService {
    private let fluidAudio: any LocalTranscriptionEngine
    private let whisperKit: any LocalTranscriptionEngine

    public init(fluidAudio: any LocalTranscriptionEngine, whisperKit: any LocalTranscriptionEngine) {
        self.fluidAudio = fluidAudio
        self.whisperKit = whisperKit
    }

    private func resolve(_ modelID: String) throws -> (LocalModel, any LocalTranscriptionEngine) {
        guard let m = LocalModelCatalog.model(id: modelID) else { throw LocalTranscriptionError.unsupportedModel(modelID) }
        switch m.runner {
        case .whisperKit: return (m, whisperKit)
        case .fluidAudioParakeet, .fluidAudioSenseVoice, .fluidAudioCohere: return (m, fluidAudio)
        }
    }

    public func transcribe(audioURL: URL, modelID: String, language: String?) async throws -> String {
        let (m, e) = try resolve(modelID)
        return try await e.transcribe(audioURL: audioURL, model: m, language: language)
    }
    public func isDownloaded(modelID: String) async throws -> Bool { let (m, e) = try resolve(modelID); return await e.isDownloaded(m) }
    public func installedBytes(modelID: String) async throws -> Int64 { let (m, e) = try resolve(modelID); return await e.installedBytes(m) }
    public func download(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (m, e) = try resolve(modelID); try await e.download(m, progress: progress)
    }
    public func delete(modelID: String) async throws { let (m, e) = try resolve(modelID); try await e.delete(m) }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalTranscriptionServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionService.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalTranscriptionServiceTests.swift
git commit -m "feat(local): service routing modelID to FluidAudio/WhisperKit engines"
```

### Task 6: `LocalModelsStore` — observable UI state

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/LocalModelsStore.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelsStoreTests.swift`

**Interfaces:**
- Consumes: `LocalTranscriptionService`, `LocalModelCatalog`.
- Produces: `@MainActor @Observable final class LocalModelsStore` with `init(service:)`, `struct ModelState { var isDownloaded; var isDownloading; var progress: Double; var installedBytes: Int64 }`, `private(set) var states: [String: ModelState]`, `func refresh() async`, `func download(_ model: LocalModel) async`, `func delete(_ model: LocalModel) async`, `var lastError: String?`.

- [ ] **Step 1: Write the failing test**

```swift
// LocalModelsStoreTests.swift
import Foundation
import Testing
@testable import LocalTranscription

@MainActor @Test func downloadThenDeleteUpdatesState() async {
    let svc = LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine())
    let store = LocalModelsStore(service: svc)
    let model = LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!

    await store.download(model)
    #expect(store.states["parakeet-tdt-ctc-110m"]?.isDownloaded == true)
    #expect(store.states["parakeet-tdt-ctc-110m"]?.isDownloading == false)
    #expect((store.states["parakeet-tdt-ctc-110m"]?.progress ?? 0) == 1.0)

    await store.delete(model)
    #expect(store.states["parakeet-tdt-ctc-110m"]?.isDownloaded == false)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelsStoreTests`
Expected: FAIL — `LocalModelsStore` undefined.

- [ ] **Step 3: Implement**

```swift
// LocalModelsStore.swift
import Foundation

@MainActor @Observable public final class LocalModelsStore {
    public struct ModelState: Sendable, Equatable {
        public var isDownloaded = false
        public var isDownloading = false
        public var progress: Double = 0
        public var installedBytes: Int64 = 0
    }

    public private(set) var states: [String: ModelState] = [:]
    public var lastError: String?
    private let service: LocalTranscriptionService

    public init(service: LocalTranscriptionService) {
        self.service = service
        for m in LocalModelCatalog.all { states[m.id] = ModelState() }
    }

    public func refresh() async {
        for m in LocalModelCatalog.all {
            let downloaded = (try? await service.isDownloaded(modelID: m.id)) ?? false
            let bytes = downloaded ? ((try? await service.installedBytes(modelID: m.id)) ?? 0) : 0
            states[m.id, default: ModelState()].isDownloaded = downloaded
            states[m.id, default: ModelState()].installedBytes = bytes
        }
    }

    public func download(_ model: LocalModel) async {
        states[model.id, default: ModelState()].isDownloading = true
        states[model.id, default: ModelState()].progress = 0
        do {
            try await service.download(modelID: model.id) { [weak self] p in
                Task { @MainActor in self?.states[model.id, default: ModelState()].progress = p }
            }
            states[model.id, default: ModelState()].isDownloaded = true
            states[model.id, default: ModelState()].installedBytes = (try? await service.installedBytes(modelID: model.id)) ?? 0
        } catch {
            lastError = error.localizedDescription
        }
        states[model.id, default: ModelState()].isDownloading = false
    }

    public func delete(_ model: LocalModel) async {
        do {
            try await service.delete(modelID: model.id)
            states[model.id, default: ModelState()].isDownloaded = false
            states[model.id, default: ModelState()].installedBytes = 0
        } catch { lastError = error.localizedDescription }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter LocalModelsStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/LocalModelsStore.swift Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalModelsStoreTests.swift
git commit -m "feat(local): observable models store (download/delete/progress state)"
```

---

## Phase D — Real engine adapters (device-verified)

> These wrap the real packages, so they cannot run in the autonomous SPM suite (network + ANE + multi-GB downloads). Each task's verification is: build the app, open the (Task 11) Models page, download the model, transcribe a sample recording, and eyeball the transcript. Use the smallest model (`parakeet-tdt-ctc-110m`, ~217 MB) to verify the FluidAudio path first.

### Task 7: `FluidAudioEngine` — Parakeet family (110m / v3 / ja)

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift`

**Interfaces:**
- Produces: `actor FluidAudioEngine: LocalTranscriptionEngine` handling `runner == .fluidAudioParakeet` (Task 8/10 extend it for SenseVoice/Cohere).

- [ ] **Step 1: Implement the Parakeet path** (signatures per `docs/local-transcription-api-reference.md` §A)

```swift
// FluidAudioEngine.swift
import Foundation
import FluidAudio

public actor FluidAudioEngine: LocalTranscriptionEngine {
    public init() {}

    private func parakeetVersion(_ selector: String) -> AsrModelVersion {
        switch selector {
        case "v3": return .v3
        case "v2": return .v2
        case "tdtCtc110m": return .tdtCtc110m
        case "tdtJa": return .tdtJa
        default: return .v3
        }
    }

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        guard model.runner == .fluidAudioParakeet,
              let dir = try? ModelStorage.runnerDir(.fluidAudioParakeet) else { return false }
        return AsrModels.modelsExist(at: dir, version: parakeetVersion(model.selector), encoderPrecision: .int8)
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 {
        guard let dir = try? ModelStorage.runnerDir(model.runner) else { return 0 }
        return ModelStorage.directorySize(dir)
    }

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        _ = try await AsrModels.download(to: dir, version: parakeetVersion(model.selector),
                                         encoderPrecision: .int8) { p in progress(p.fractionCompleted) }
    }

    public func delete(_ model: LocalModel) async throws {
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        // Per §A2; if clearModelCache(forRepo:) is impractical for the selected version,
        // remove the model's cache subfolder directly with FileManager.
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: parakeetVersion(model.selector)))
        _ = dir
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else { throw LocalTranscriptionError.modelNotDownloaded(model.displayName) }
        let dir = try ModelStorage.runnerDir(.fluidAudioParakeet)
        let models = try await AsrModels.load(from: dir, version: parakeetVersion(model.selector))
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        var state = try TdtDecoderState(decoderLayers: asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state,
                                              language: model.selector == "v3" ? language.map(Language.init) : nil)
        return result.text
    }
}
```

> Verify exact `AsrModels.download(to:version:…)` + `AsrModels.load(from:version:)` argument labels and the `Language` init against the pinned FluidAudio tag — the API reference notes the docs are stale. Adjust if the resolver version differs.

- [ ] **Step 2: Build the module**

Run: `swift build --disable-sandbox --package-path Packages/AudioPipeline`
Expected: compiles.

- [ ] **Step 3: Commit** (device verification happens after Task 11)

```bash
git add Packages/AudioPipeline/Sources/LocalTranscription/FluidAudioEngine.swift
git commit -m "feat(local): FluidAudio engine — Parakeet TDT 110m/v3/ja"
```

### Task 8: `FluidAudioEngine` — SenseVoice

- [ ] **Step 1:** Extend `FluidAudioEngine` to handle `runner == .fluidAudioSenseVoice` using `SenseVoiceManager.load(precision: .fp16)` (per §A1/§A4), `SenseVoiceModels.modelsExist(...)` for `isDownloaded`, and the SenseVoice `transcribe` returning a bare `String`. Store under `ModelStorage.runnerDir(.fluidAudioSenseVoice)`.
- [ ] **Step 2:** `swift build …` — compiles.
- [ ] **Step 3:** Commit `feat(local): FluidAudio engine — SenseVoice Small`.

### Task 9: `WhisperKitEngine` — large-v3-turbo

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/WhisperKitEngine.swift`

- [ ] **Step 1: Implement** (per §B; override `downloadBase` to Application Support; hand-roll list/delete/size)

```swift
// WhisperKitEngine.swift
import Foundation
import WhisperKit

public actor WhisperKitEngine: LocalTranscriptionEngine {
    public init() {}

    private func variantDir(_ model: LocalModel) throws -> URL {
        try ModelStorage.runnerDir(.whisperKit)
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model.selector)", isDirectory: true)
    }

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        (try? variantDir(model)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
    public func installedBytes(_ model: LocalModel) async -> Int64 {
        (try? variantDir(model)).map { ModelStorage.directorySize($0) } ?? 0
    }
    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = try ModelStorage.runnerDir(.whisperKit)
        _ = try await WhisperKit.download(variant: model.selector, downloadBase: base) { p in
            progress(p.fractionCompleted)
        }
    }
    public func delete(_ model: LocalModel) async throws {
        try FileManager.default.removeItem(at: try variantDir(model))
    }
    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        guard await isDownloaded(model) else { throw LocalTranscriptionError.modelNotDownloaded(model.displayName) }
        let base = try ModelStorage.runnerDir(.whisperKit)
        let pipe = try await WhisperKit(WhisperKitConfig(model: model.selector, downloadBase: base, download: false))
        let opts = DecodingOptions(language: language, chunkingStrategy: .vad)
        let results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: opts)
        return results.map(\.text).joined(separator: " ")
    }
}
```

- [ ] **Step 2:** `swift build …` — compiles.
- [ ] **Step 3:** Commit `feat(local): WhisperKit engine — large-v3-turbo`.

### Task 10: `FluidAudioEngine` — Cohere Transcribe

> Most complex adapter: no auto-download (stage the repo), 35 s/call cap → `transcribeLong` (§A5).

- [ ] **Step 1:** Extend `FluidAudioEngine` for `runner == .fluidAudioCohere`: download via `DownloadUtils.downloadRepo(.cohereTranscribeCoreml, …)` into `ModelStorage.runnerDir(.fluidAudioCohere)`; `isDownloaded` by checking the staged dirs exist; `transcribe` via `CoherePipeline.loadModels(encoderDir:decoderDir:vocabDir:)` then **`transcribeLong(audio:models:language:)`** (passing the language explicitly, default English), returning its `TranscriptionResult.text`.
- [ ] **Step 2:** `swift build …` — compiles.
- [ ] **Step 3:** Commit `feat(local): FluidAudio engine — Cohere Transcribe (transcribeLong)`.

---

## Phase E — Models page UI

### Task 11: `ModelsView` + `ModelRowView`

**Files:**
- Create: `Amanuensis/UI/Models/ModelsView.swift`, `Amanuensis/UI/Models/ModelRowView.swift`

**Interfaces:**
- Consumes: `LocalModelsStore`, `LocalModelCatalog`, `LocalModel`.

- [ ] **Step 1: Implement the row** (description, languages, footprint, download/delete + progress)

```swift
// ModelRowView.swift
import SwiftUI
import LocalTranscription

struct ModelRowView: View {
    let model: LocalModel
    let state: LocalModelsStore.ModelState
    let onDownload: () -> Void
    let onDelete: () -> Void

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(model.displayName).font(.headline)
                         if model.recommended { Text("Recommended").font(.caption2).padding(.horizontal, 6)
                             .background(.tint.opacity(0.2)).clipShape(Capsule()) } }
                Text(model.summary).font(.subheadline).foregroundStyle(.secondary)
                Text("\(model.languages) · \(state.isDownloaded ? fmt(state.installedBytes) : "~\(fmt(model.approxBytes))")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isDownloading { ProgressView(value: state.progress).frame(width: 90) }
            else if state.isDownloaded { Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } }
            else { Button("Download", action: onDownload) }
        }.padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Implement the page**

```swift
// ModelsView.swift
import SwiftUI
import LocalTranscription

struct ModelsView: View {
    @Bindable var store: LocalModelsStore
    var body: some View {
        List(LocalModelCatalog.all) { model in
            ModelRowView(model: model,
                         state: store.states[model.id] ?? .init(),
                         onDownload: { Task { await store.download(model) } },
                         onDelete: { Task { await store.delete(model) } })
        }
        .task { await store.refresh() }
        .navigationTitle("On-device models")
    }
}
```

- [ ] **Step 3: Build the app target**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: app compiles.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/UI/Models
git commit -m "feat(local): Models page UI (download/delete/size/languages)"
```

### Task 12: Surface the Models page + wire the store

**Files:**
- Modify: `Amanuensis/UI/SettingsView.swift` (add a "Models" section/link near Dictation, `SettingsView.swift:61`)
- Modify: `Amanuensis/AppCoordinator.swift` (construct `LocalTranscriptionService` + `LocalModelsStore`, expose to UI)

- [ ] **Step 1:** In `AppCoordinator`, build the composition root objects once:

```swift
let localService = LocalTranscriptionService(fluidAudio: FluidAudioEngine(), whisperKit: WhisperKitEngine())
let localModelsStore = LocalModelsStore(service: localService)
```

- [ ] **Step 2:** Add a navigation entry in `SettingsView` that pushes `ModelsView(store: coordinator.localModelsStore)`.
- [ ] **Step 3: Device verification (covers Tasks 7–10):** build + run; open Settings → Models; download **Parakeet TDT-CTC 110M**; confirm progress → "Download" becomes a trash button and size shows ~217 MB. Repeat for one WhisperKit model and one other FluidAudio model. Delete one and confirm it reverts.

Run app: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -destination 'platform=macOS' build` then launch.

- [ ] **Step 4: Commit**

```bash
git add Amanuensis/AppCoordinator.swift Amanuensis/UI/SettingsView.swift
git commit -m "feat(local): surface Models page and wire LocalTranscription service"
```

---

## Phase F — Jobs integration

### Task 13: `JobShape.localTranscription` + `requiresAPIKey` + fields

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobShape.swift:4` (add case + `baseURLPathHint`/`requiresModel` arms + new `requiresAPIKey`)
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/FieldSpec.swift:30`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobShapeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func localTranscriptionShapeIsKeylessAndNeedsModel() {
    #expect(JobShape.localTranscription.requiresAPIKey == false)
    #expect(JobShape.chatCompletionsAudio.requiresAPIKey == true)
    #expect(JobShape.localTranscription.requiresModel == true)
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test … --filter JobShapeTests` → FAIL (`localTranscription` / `requiresAPIKey` undefined).

- [ ] **Step 3: Implement** — add `case localTranscription` to `JobShape`; in its `baseURLPathHint` return `""`, in `requiresModel` return `true`; add:

```swift
public var requiresAPIKey: Bool { self != .localTranscription }
```

and a `.localTranscription` arm in the `fields` switch (`FieldSpec.swift`): one optional field
`FieldSpec(key: "language", label: "Language (optional)", kind: .text, required: false, help: "e.g. en, ja, zh — leave blank to auto-detect")`.

- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** `feat(jobs): add localTranscription shape (keyless, model-driven)`.

### Task 14: `JobRunner` — skip key fetch for keyless shapes

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/JobRunner.swift:39`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/JobRunnerTests.swift`

- [ ] **Step 1: Write the failing test** — a stub `KeychainProviding` that records whether `get` was called, plus a stub `AudioJobSending`; run a `localTranscription` job and assert the keychain was **not** queried and the handler received `apiKey == ""`.

```swift
@Test func localShapeSkipsKeychainFetch() async throws {
    let kc = SpyKeychain()                  // records get(account:) calls; returns "should-not-be-used"
    let spy = SpySender()                   // captures apiKey; returns "ok"
    let runner = JobRunner(keychain: kc, handlers: [.localTranscription: spy])
    _ = try await runner.run(job: localJob, provider: localProvider, shape: .localTranscription,
                             audioURL: URL(fileURLWithPath: "/x.flac"))
    #expect(kc.getCalled == false)
    #expect(spy.receivedAPIKey == "")
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement** — at `JobRunner.swift:39` replace the unconditional fetch:

```swift
let apiKey = shape.requiresAPIKey ? try keychain.get(account: provider.apiKeyRef.account) : ""
```

- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** `feat(jobs): JobRunner skips keychain fetch for keyless shapes`.

### Task 15: `LocalTranscriptionSender` handler

**Files:**
- Create: `Packages/AudioPipeline/Sources/LocalTranscription/LocalTranscriptionSender.swift`
- Test: `Packages/AudioPipeline/Tests/LocalTranscriptionTests/LocalTranscriptionSenderTests.swift`

**Interfaces:**
- Consumes: `AudioJobSending`, `Job`, `Provider` (from `AudioPipelineJobs`), `LocalTranscriptionService`.
- Produces: `struct LocalTranscriptionSender: AudioJobSending` with `init(service:)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AudioPipelineJobs
@testable import LocalTranscription

@Test func senderTranscribesViaServiceUsingJobModel() async throws {
    let fa = FakeEngine(); try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!) { _ in }
    let svc = LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine())
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft(); job.model = "parakeet-tdt-ctc-110m"
    let text = try await sender.send(job: job, provider: .localStub, audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: "")
    #expect(text == "fake transcript")
}

@Test func senderRejectsUnknownModel() async {
    let sender = LocalTranscriptionSender(service: .init(fluidAudio: FakeEngine(), whisperKit: FakeEngine()))
    var job = Job.makeDraft(); job.model = "bogus"
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await sender.send(job: job, provider: .localStub, audioURL: URL(fileURLWithPath: "/x"), apiKey: "")
    }
}
```

(Add a `Provider.localStub` test helper, or build a minimal `Provider` inline matching its initializer.)

- [ ] **Step 2: Run to verify it fails** — FAIL.
- [ ] **Step 3: Implement**

```swift
// LocalTranscriptionSender.swift
import Foundation
import AudioPipelineJobs

public struct LocalTranscriptionSender: AudioJobSending {
    private let service: LocalTranscriptionService
    public init(service: LocalTranscriptionService) { self.service = service }

    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        guard LocalModelCatalog.model(id: job.model) != nil else {
            throw LocalTranscriptionError.unsupportedModel(job.model)
        }
        return try await service.transcribe(audioURL: audioURL, modelID: job.model,
                                            language: job.fields["language"].flatMap { $0.isEmpty ? nil : $0 })
    }
}
```

- [ ] **Step 4: Run to verify it passes** — PASS.
- [ ] **Step 5: Commit** `feat(local): AudioJobSending handler for on-device transcription`.

### Task 16: Built-in preset + provider editor + AppCoordinator wiring (end-to-end)

**Files:**
- Modify: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json`
- Modify: `Amanuensis/UI/Providers/ProviderEditorView.swift:84`
- Modify: `Amanuensis/AppCoordinator.swift:354`

- [ ] **Step 1: Add the preset row** to `presets.json`:

```json
{ "id": "on-device", "displayName": "On-device (local)", "shape": "localTranscription",
  "baseURL": "", "suggestedModels": ["parakeet-tdt-ctc-110m","parakeet-tdt-v3","cohere-transcribe","whisper-large-v3-turbo","parakeet-tdt-ja","sensevoice-small"],
  "defaultOutputExt": "txt" }
```

- [ ] **Step 2: Relax `ProviderEditorView.canSave`** (`:84`) so a keyless shape doesn't require an API-key account:

```swift
var canSave: Bool {
    let needsKey = preset?.shape.requiresAPIKey ?? true
    return !name.isEmpty && (!needsKey || !apiKeyAccount.isEmpty)
}
```

- [ ] **Step 3: Inject the handler** in `AppCoordinator.runJob` (`:354`) — merge the local sender into the runner's handlers:

```swift
let handlers = JobRunner.defaultHandlers.merging(
    [.localTranscription: LocalTranscriptionSender(service: localService)]) { _, new in new }
let runner = JobRunner(keychain: keychain, handlers: handlers)
```

(If `JobRunner` lacks an `init(keychain:handlers:)`, add it with `handlers` defaulting to `defaultHandlers` — small, covered by Task 14's test setup.)

- [ ] **Step 4: SPM tests + app build**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Then: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: all green.

- [ ] **Step 5: End-to-end device verification** — launch the app: create an "On-device" provider from the preset (saves with **no API key**); on a recording, run a job with that provider + model `parakeet-tdt-ctc-110m`; confirm a `.txt` transcript is written next to the recording and the text is plausible. Try a non-downloaded model and confirm the friendly "not downloaded" error appears in the Logs view.

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Resources/presets.json Amanuensis/UI/Providers/ProviderEditorView.swift Amanuensis/AppCoordinator.swift
git commit -m "feat(local): on-device preset, keyless provider editor, JobRunner wiring"
```

---

## Phase G — Docs & deferred next steps

### Task 17: Record deferred work

- [ ] **Step 1:** Append a "Deferred / next steps" note to `docs/local-transcription-backend-research.md` (and/or a new `docs/local-transcription-next-steps.md`) capturing:
  - **Streaming / live dictation** — a `LocalTranscriber: DictationTranscriber` (`onPartial`/`onFinal`) over FluidAudio Parakeet EOU + Nemotron Streaming Multilingual (true streaming) and/or WhisperKit `AudioStreamTranscriber`; reuse the realtime-doc commit-window UX. Separate seam from `AudioJobSending` (see `docs/local-transcription-backend-research.md` §7–8).
  - **IndicConformer-600M Core ML RNNT** (Hindi, MIT, ~13 WER) — a fifth engine; needs a Swift greedy-RNNT decoder + log-mel frontend (`phequals/indic-conformer-600m-multilingual-coreml-rnnt`; Muesli `pHequals7/muesli` is the reference). The RNNT decode overlaps FluidAudio's Parakeet path.
  - **Background Assets** for model delivery (vs the current per-runner HF download) if/when MAS hosting is wanted.
- [ ] **Step 2: Commit** `docs(local): record deferred streaming + IndicConformer next steps`.

---

## Self-Review

- **Spec coverage:** packages bundled (Task 1) ✓; Models page download/delete/description/languages/footprint (Tasks 11–12) ✓; the six models (Task 2 catalog + Tasks 7–10 adapters) ✓; streaming + IndicConformer deferred & documented (Task 17) ✓; end-to-end batch transcription (Tasks 13–16) ✓.
- **Placeholder scan:** real code given for every new type; modification tasks cite exact `file:line`. Adapter steps (7–10) name the exact package calls from the API reference; Cohere/SenseVoice steps point at the specific managers rather than restating code (acceptable: they mirror Task 7's structure on documented signatures).
- **Type consistency:** `LocalModel.selector`, `LocalRunner` cases, `LocalTranscriptionService.transcribe(audioURL:modelID:language:)`, `LocalModelsStore.ModelState`, and `JobShape.requiresAPIKey` are used consistently across tasks.
- **Known verification gap:** real transcription, downloads, and UI run only on device (not in the SPM suite) — explicitly handled as device-verification steps in Tasks 11–12 and 16, with the fakes covering routing/handler/store logic autonomously.
