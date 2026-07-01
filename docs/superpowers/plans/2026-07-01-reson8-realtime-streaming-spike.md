# Reson8 Realtime streaming spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove live Reson8 Realtime dictation end-to-end — real mic audio streamed over a WebSocket, real partials/finals typed into the frontmost app through M1's commit-window/insertion engine — behind a DEBUG menu command.

**Architecture:** Two pure, SPM-tested helpers in `AudioPipelineJobs` (a `wss://` URL builder and a transcript decoder) plus a live `URLSessionWebSocketTask` driver; `RecordingCore` gains an `onChunk` sink that fans the already-converted 16 kHz mono Int16 buffers to the socket; a DEBUG `@MainActor` harness wires provider/key → mic → client → `CommitController` → `KeystrokeDiffInserter` → overlay + metrics, launched from the existing "Streaming Spike" menu.

**Tech Stack:** Swift 6.2, Foundation `URLSessionWebSocketTask`, AVFoundation, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), SwiftUI (menu), os `Logger`.

## Global Constraints

- **Swift 6.2**, deployment target **macOS 26.3**. Package targets `AudioPipelineJobs`, `RecordingCore`, `DictationCore` use **`nonisolatedSettings`** (default isolation is `nonisolated`, not MainActor). Cross-thread closures must be explicitly `@Sendable`.
- **App Sandbox is on**; WebSocket (`wss://`) is covered by the existing `com.apple.security.network.client` entitlement — **no entitlement change**.
- **Endpoint:** `wss://api.reson8.dev/v1/speech-to-text/realtime`. **Auth header:** `Authorization: ApiKey <key>` (user's own key from Keychain — no token exchange).
- **Config (query params):** `encoding=pcm_s16le`, `sample_rate=16000`, `channels=1`, `include_interim=true`, `language=en`. All feature flags off.
- **Audio on the wire:** raw PCM as **binary** WS frames — 16 kHz mono Int16 little-endian, exactly what `DictationWAVWriter` produces.
- **Insertion default:** keystroke / in-place (`KeystrokeDiffInserter`); clipboard `k=3` as a second variant. **Stop model:** fixed ~20 s capture window.
- **DEBUG-only** harness + menu; **no changes** to `DictationCoordinator` / hotkey / `DictationStateMachine` / `BatchTranscriber`.
- **SPM tests:** `swift test --disable-sandbox --package-path Packages/AudioPipeline`. **App build (sandbox):** `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build` (xcodebuild self-refuses in-sandbox; the helper routes to the outside-sandbox daemon).
- Commit messages: Conventional Commits; end with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.
- Spec: `docs/superpowers/specs/2026-07-01-reson8-realtime-streaming-spike-design.md`.

---

## File Structure

- **Create** `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeURL.swift` — options struct + `wss://` URL builder (pure).
- **Create** `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8StreamDecoder.swift` — `Reson8StreamEvent` + decoder (pure).
- **Create** `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeClient.swift` — live WS driver.
- **Modify** `Packages/AudioPipeline/Sources/RecordingCore/DictationWAVWriter.swift` — add `onChunk` sink.
- **Modify** `Packages/AudioPipeline/Sources/RecordingCore/DictationRecorder.swift` — thread `onChunk` through.
- **Create** `Amanuensis/Dictation/Streaming/Reson8SpikeHarness.swift` — DEBUG harness.
- **Modify** `Amanuensis/AmanuensisApp.swift` — Reson8 menu commands + thread `coordinator` in.
- **Create** `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8RealtimeURLTests.swift`.
- **Create** `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8StreamDecoderTests.swift`.
- **Modify** `Packages/AudioPipeline/Tests/RecordingCoreTests/DictationWAVWriterTests.swift` — add `onChunk` test.

---

## Task 1: Reson8 Realtime URL builder (pure)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeURL.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8RealtimeURLTests.swift`

**Interfaces:**
- Produces: `struct Reson8RealtimeOptions` (`encoding: String`, `sampleRate: Int`, `channels: Int`, `includeInterim: Bool`, `language: String`; dictation defaults). `enum Reson8RealtimeURL { static func make(baseURL: String, options: Reson8RealtimeOptions = .init()) throws -> URL; enum BuildError: Error, Equatable { case invalidBaseURL } }`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8RealtimeURLTests.swift`:

```swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct Reson8RealtimeURLBuilding {
    @Test func swapsHttpsToWss_andAppendsPath() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev")
        #expect(url.scheme == "wss")
        #expect(url.host == "api.reson8.dev")
        #expect(url.path == "/v1/speech-to-text/realtime")
    }

    @Test func trimsTrailingSlashOnBaseURL() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev/")
        #expect(url.path == "/v1/speech-to-text/realtime")
    }

    @Test func attachesDictationConfigQuery() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(q["encoding"] == "pcm_s16le")
        #expect(q["sample_rate"] == "16000")
        #expect(q["channels"] == "1")
        #expect(q["include_interim"] == "true")
        #expect(q["language"] == "en")
    }

    @Test func usesWsForLoopbackHttp() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "http://127.0.0.1:8080")
        #expect(url.scheme == "ws")
    }

    @Test func rejectsSchemelessBaseURL() {
        #expect(throws: Reson8RealtimeURL.BuildError.self) {
            _ = try Reson8RealtimeURL.make(baseURL: "api.reson8.dev")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter Reson8RealtimeURLBuilding`
Expected: FAIL — `cannot find 'Reson8RealtimeURL' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeURL.swift`:

```swift
import Foundation

/// Query configuration for the Reson8 Realtime WebSocket. Defaults are tuned for
/// dictation: raw 16 kHz mono Int16 PCM, interim results on, English pinned.
public struct Reson8RealtimeOptions: Sendable, Equatable {
    public var encoding: String
    public var sampleRate: Int
    public var channels: Int
    public var includeInterim: Bool
    public var language: String

    public init(encoding: String = "pcm_s16le",
                sampleRate: Int = 16_000,
                channels: Int = 1,
                includeInterim: Bool = true,
                language: String = "en") {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channels = channels
        self.includeInterim = includeInterim
        self.language = language
    }
}

/// Builds the Reson8 Realtime `wss://` URL from a provider base URL + options.
public enum Reson8RealtimeURL {
    public enum BuildError: Error, Equatable { case invalidBaseURL }

    public static let path = "/v1/speech-to-text/realtime"

    /// Swaps the base URL's scheme to `wss` (or `ws` for loopback `http`),
    /// appends the realtime path, and attaches the config as query items in a
    /// stable order. Throws if the base URL has no scheme.
    public static func make(baseURL: String,
                            options: Reson8RealtimeOptions = .init()) throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var comps = URLComponents(string: trimmed + path),
              let scheme = comps.scheme?.lowercased() else {
            throw BuildError.invalidBaseURL
        }
        comps.scheme = (scheme == "http") ? "ws" : "wss"
        comps.queryItems = [
            URLQueryItem(name: "encoding", value: options.encoding),
            URLQueryItem(name: "sample_rate", value: String(options.sampleRate)),
            URLQueryItem(name: "channels", value: String(options.channels)),
            URLQueryItem(name: "include_interim", value: options.includeInterim ? "true" : "false"),
            URLQueryItem(name: "language", value: options.language),
        ]
        guard let url = comps.url else { throw BuildError.invalidBaseURL }
        return url
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter Reson8RealtimeURLBuilding`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeURL.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8RealtimeURLTests.swift
git commit -m "feat(dictation): add Reson8 Realtime wss URL builder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Reson8 transcript decoder (pure)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8StreamDecoder.swift`
- Test: `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8StreamDecoderTests.swift`

**Interfaces:**
- Produces: `enum Reson8StreamEvent: Sendable, Equatable { case partial(String); case final(String); case flushConfirmed(id: String?); case ignored }`. `enum Reson8StreamDecoder { static func decode(_ json: String) -> Reson8StreamEvent }` — never throws.

- [ ] **Step 1: Write the failing tests**

Create `Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8StreamDecoderTests.swift`:

```swift
import Testing
@testable import AudioPipelineJobs

@Suite struct Reson8StreamDecoding {
    @Test func interimTranscript_isPartial() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","text":"the patient","is_final":false}"#)
        #expect(e == .partial("the patient"))
    }
    @Test func finalTranscript_isFinal() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","text":"the patient presented","is_final":true}"#)
        #expect(e == .final("the patient presented"))
    }
    @Test func transcriptWithoutIsFinal_defaultsToFinal() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","text":"hello"}"#)
        #expect(e == .final("hello"))
    }
    @Test func transcriptWithoutText_isIgnored() {
        let e = Reson8StreamDecoder.decode(#"{"type":"transcript","is_final":true}"#)
        #expect(e == .ignored)
    }
    @Test func flushConfirmationWithID() {
        let e = Reson8StreamDecoder.decode(#"{"type":"flush_confirmation","id":"stop"}"#)
        #expect(e == .flushConfirmed(id: "stop"))
    }
    @Test func flushConfirmationWithoutID() {
        let e = Reson8StreamDecoder.decode(#"{"type":"flush_confirmation"}"#)
        #expect(e == .flushConfirmed(id: nil))
    }
    @Test func unknownType_isIgnored() {
        #expect(Reson8StreamDecoder.decode(#"{"type":"turn_start"}"#) == .ignored)
    }
    @Test func malformedJSON_isIgnored() {
        #expect(Reson8StreamDecoder.decode("not json at all") == .ignored)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter Reson8StreamDecoding`
Expected: FAIL — `cannot find 'Reson8StreamDecoder' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8StreamDecoder.swift`:

```swift
import Foundation

/// A decoded Reson8 Realtime server message, normalized for the commit window.
public enum Reson8StreamEvent: Sendable, Equatable {
    case partial(String)              // interim transcript (is_final == false)
    case final(String)                // final transcript (is_final == true, or interim off)
    case flushConfirmed(id: String?)  // response to a flush_request
    case ignored                      // unknown type, non-transcript, or malformed
}

/// Pure decoder for Reson8 Realtime text frames. Never throws — a stray or
/// malformed frame must not tear down the stream; it decodes to `.ignored`.
public enum Reson8StreamDecoder {
    private struct Message: Decodable {
        let type: String
        let text: String?
        let isFinal: Bool?
        let id: String?
        enum CodingKeys: String, CodingKey {
            case type, text, id
            case isFinal = "is_final"
        }
    }

    public static func decode(_ json: String) -> Reson8StreamEvent {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            return .ignored
        }
        switch msg.type {
        case "transcript":
            guard let text = msg.text else { return .ignored }
            // With include_interim off, `is_final` is absent and every transcript
            // is already final → treat a missing flag as final.
            return (msg.isFinal ?? true) ? .final(text) : .partial(text)
        case "flush_confirmation":
            return .flushConfirmed(id: msg.id)
        default:
            return .ignored
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter Reson8StreamDecoding`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8StreamDecoder.swift \
        Packages/AudioPipeline/Tests/AudioPipelineJobsTests/Reson8StreamDecoderTests.swift
git commit -m "feat(dictation): add Reson8 Realtime transcript decoder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Reson8 Realtime WebSocket client (live I/O)

**Files:**
- Create: `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeClient.swift`

**Interfaces:**
- Consumes: `Reson8StreamDecoder.decode` (Task 2).
- Produces: `final class Reson8RealtimeClient: @unchecked Sendable` with `init(url: URL, apiKey: String, session: URLSession = .shared, onPartial: @escaping @Sendable (String) -> Void, onFinal: @escaping @Sendable (String) -> Void, onError: @escaping @Sendable (Error) -> Void = { _ in })`, `func start()`, `func send(_ pcm: Data)`, `func finish() async`.

No unit test — this is untestable live socket I/O (its decode/URL dependencies are tested in Tasks 1–2, and it is exercised end-to-end by the manual spike in Task 6). The deliverable is verified by compilation.

- [ ] **Step 1: Write the implementation**

Create `Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeClient.swift`:

```swift
import Foundation
import os

/// Drives a Reson8 Realtime WebSocket: streams raw PCM up as binary frames and
/// decodes transcript messages down into `onPartial`/`onFinal`. `@unchecked
/// Sendable` — the audio thread calls `send(_:)` while the receive loop runs on
/// URLSession's delegate queue; both funnel through the thread-safe task.
public final class Reson8RealtimeClient: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onPartial: @Sendable (String) -> Void
    private let onFinal: @Sendable (String) -> Void
    private let onError: @Sendable (Error) -> Void
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "reson8-rt")

    public init(url: URL,
                apiKey: String,
                session: URLSession = .shared,
                onPartial: @escaping @Sendable (String) -> Void,
                onFinal: @escaping @Sendable (String) -> Void,
                onError: @escaping @Sendable (Error) -> Void = { _ in }) {
        var request = URLRequest(url: url)
        request.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        self.task = session.webSocketTask(with: request)
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
    }

    /// Opens the socket and arms the receive loop.
    public func start() {
        task.resume()
        receive()
    }

    /// Sends one raw-PCM chunk as a binary frame. Non-blocking; safe to call from
    /// the audio thread. Send failures are logged, not thrown.
    public func send(_ pcm: Data) {
        task.send(.data(pcm)) { [log] error in
            if let error {
                log.error("send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Flushes buffered audio, gives trailing finals ~1 s to arrive, then closes.
    public func finish() async {
        let flush = #"{"type":"flush_request","id":"stop"}"#
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task.send(.string(flush)) { _ in cont.resume() }
        }
        try? await Task.sleep(for: .seconds(1))
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                // Socket closed or errored — stop re-arming. On our own `finish()`
                // this fires with a benign normal-closure error.
                self.onError(error)
            case .success(let message):
                if case .string(let text) = message {
                    switch Reson8StreamDecoder.decode(text) {
                    case .partial(let t): self.onPartial(t)
                    case .final(let t): self.onFinal(t)
                    case .flushConfirmed(let id):
                        self.log.debug("flush confirmed id=\(id ?? "nil", privacy: .public)")
                    case .ignored:
                        break
                    }
                }
                self.receive()   // re-arm for the next frame
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --package-path Packages/AudioPipeline`
Expected: `Build complete!` with no errors or concurrency warnings.

- [ ] **Step 3: Commit**

```bash
git add Packages/AudioPipeline/Sources/AudioPipelineJobs/Reson8RealtimeClient.swift
git commit -m "feat(dictation): add Reson8 Realtime WebSocket client

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `onChunk` audio fan-out in RecordingCore

**Files:**
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/DictationWAVWriter.swift`
- Modify: `Packages/AudioPipeline/Sources/RecordingCore/DictationRecorder.swift`
- Test: `Packages/AudioPipeline/Tests/RecordingCoreTests/DictationWAVWriterTests.swift`

**Interfaces:**
- Produces: `DictationWAVWriter.init(url:inputFormat:onLevel:onChunk:)` and `DictationRecorder.init(url:onLevel:onChunk:)`, where `onChunk: (@Sendable (Data) -> Void)? = nil` receives each converted buffer's interleaved Int16 bytes (`pcm_s16le`). One `Int16` sample per written frame, so `emittedBytes / 2 == framesWritten`.

- [ ] **Step 1: Write the failing test**

Add to `Packages/AudioPipeline/Tests/RecordingCoreTests/DictationWAVWriterTests.swift` (a thread-safe collector + a new `@Test` inside the existing `@Suite struct DictationWAVWriterTests`):

```swift
    // Collects onChunk output across the writer's private queue; read only after
    // `close()`, whose await is a happens-before barrier over the queued writes.
    private final class ChunkCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    @Test func onChunk_emitsInt16Bytes_oneSamplePerWrittenFrame() async throws {
        try await withTempDirectory { tempURL in
            let url = tempURL.appending(path: "dictation.wav", directoryHint: .notDirectory)
            let inputFormat = SyntheticAudio.stereo48kHz
            let collector = ChunkCollector()
            let writer = try DictationWAVWriter(
                url: url, inputFormat: inputFormat, onLevel: nil,
                onChunk: { collector.append($0) })

            for count: AVAudioFrameCount in [4800, 4800, 4800] {
                writer.enqueue(SyntheticAudio.makeBuffer(format: inputFormat, frameCount: count))
            }
            let frames = await writer.close()

            let bytes = collector.bytes
            #expect(!bytes.isEmpty)
            #expect(bytes.count % MemoryLayout<Int16>.size == 0)   // whole Int16 samples
            #expect(Int64(bytes.count / MemoryLayout<Int16>.size) == frames)
        }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationWAVWriterTests`
Expected: FAIL — `extra argument 'onChunk' in call`.

- [ ] **Step 3: Add the `onChunk` sink to `DictationWAVWriter`**

In `Packages/AudioPipeline/Sources/RecordingCore/DictationWAVWriter.swift`:

Add a stored property next to `onLevel`:

```swift
    private let onLevel: (@Sendable (Float) -> Void)?
    private let onChunk: (@Sendable (Data) -> Void)?
```

Change the initializer signature and body to accept and store it:

```swift
    init(url: URL, inputFormat: AVAudioFormat,
         onLevel: (@Sendable (Float) -> Void)?,
         onChunk: (@Sendable (Data) -> Void)? = nil) throws {
        self.onLevel = onLevel
        self.onChunk = onChunk
```

In `enqueue(_:)`, replace the final write block:

```swift
            guard status != .error, err == nil, out.frameLength > 0 else { return }
            if (try? file.write(from: out)) != nil {
                self.frames += Int64(out.frameLength)
            }
```

with one that also emits the converted samples as `pcm_s16le` bytes:

```swift
            guard status != .error, err == nil, out.frameLength > 0 else { return }
            if let onChunk = self.onChunk, let base = out.int16ChannelData?[0] {
                let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
                onChunk(Data(bytes: base, count: byteCount))
            }
            if (try? file.write(from: out)) != nil {
                self.frames += Int64(out.frameLength)
            }
```

- [ ] **Step 4: Thread `onChunk` through `DictationRecorder`**

In `Packages/AudioPipeline/Sources/RecordingCore/DictationRecorder.swift`, change the initializer to accept and forward it:

```swift
    public init(url: URL,
                onLevel: (@Sendable (Float) -> Void)? = nil,
                onChunk: (@Sendable (Data) -> Void)? = nil) throws {
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw DictationRecorderError.noInput
        }
        self.writer = try DictationWAVWriter(
            url: url, inputFormat: input, onLevel: onLevel, onChunk: onChunk)
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline --filter DictationWAVWriterTests`
Expected: PASS (both the existing conversion test and the new `onChunk` test).

- [ ] **Step 6: Commit**

```bash
git add Packages/AudioPipeline/Sources/RecordingCore/DictationWAVWriter.swift \
        Packages/AudioPipeline/Sources/RecordingCore/DictationRecorder.swift \
        Packages/AudioPipeline/Tests/RecordingCoreTests/DictationWAVWriterTests.swift
git commit -m "feat(dictation): fan converted PCM chunks from the dictation writer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: DEBUG Reson8 spike harness

**Files:**
- Create: `Amanuensis/Dictation/Streaming/Reson8SpikeHarness.swift`

**Interfaces:**
- Consumes: `Reson8RealtimeURL.make` (Task 1), `Reson8RealtimeClient` (Task 3), `DictationRecorder.init(url:onLevel:onChunk:)` (Task 4); M1's `CommitController`, `ScriptKind`, `InsertionStrategy`, `SpikeOverlayPanel`, `SpikeMetrics`, `TextInserter`; `ProvidersStore`, `KeychainStore`, `Provider.apiKeyRef.account`.
- Produces: `@MainActor final class Reson8SpikeHarness` with `init(providers: ProvidersStore, keychain: KeychainStore, strategy: InsertionStrategy, stabilityCount: Int = 3, captureSeconds: Int = 20)` and `func run() async`.

No unit test — DEBUG `@MainActor` AppKit + live mic + socket. Verified by app build (Task 6) and the manual smoke run.

- [ ] **Step 1: Write the harness**

Create `Amanuensis/Dictation/Streaming/Reson8SpikeHarness.swift`:

```swift
#if DEBUG
import Foundation
import DictationCore
import RecordingCore
import AudioPipelineJobs
import os

/// DEBUG-only driver: streams live mic audio to Reson8 Realtime, runs the
/// transcripts through the commit window into the frontmost app via a chosen
/// strategy, shows the volatile tail in an overlay, and logs metrics. Mirrors
/// `StreamingSpikeHarness` but with a real WebSocket source instead of a script.
@MainActor
final class Reson8SpikeHarness {
    private let providers: ProvidersStore
    private let keychain: KeychainStore
    private let strategy: InsertionStrategy
    private let captureSeconds: Int
    private let overlay = SpikeOverlayPanel()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "spike")

    private var commit: CommitController
    private var metrics = SpikeMetrics()
    private var firstWordAt: TimeInterval?
    private var start = Date()

    init(providers: ProvidersStore, keychain: KeychainStore,
         strategy: InsertionStrategy, stabilityCount: Int = 3, captureSeconds: Int = 20) {
        self.providers = providers
        self.keychain = keychain
        self.strategy = strategy
        self.captureSeconds = captureSeconds
        self.commit = CommitController(stabilityCount: stabilityCount)
    }

    func run() async {
        guard let provider = providers.providers.first(where: { $0.presetID == "reson8" }) else {
            return await failEarly("No Reson8 provider configured", detail: "no reson8 provider")
        }
        let apiKey: String
        do {
            apiKey = try await keychain.get(account: provider.apiKeyRef.account)
        } catch {
            return await failEarly("No Reson8 API key",
                                   detail: "key lookup failed: \(error.localizedDescription)")
        }
        let url: URL
        do {
            url = try Reson8RealtimeURL.make(baseURL: provider.baseURL)
        } catch {
            return await failEarly("Bad Reson8 base URL", detail: provider.baseURL)
        }

        _ = TextInserter.requestPostEventAccess()
        overlay.show()
        strategy.reset()

        for n in stride(from: 3, through: 1, by: -1) {
            overlay.render(committed: "", volatile: "Starting in \(n)…")
            try? await Task.sleep(for: .seconds(1))
        }

        start = Date()

        // Bridge the off-thread client callbacks onto this MainActor via a stream.
        let (stream, cont) = AsyncStream<ScriptKind>.makeStream()
        let client = Reson8RealtimeClient(
            url: url, apiKey: apiKey,
            onPartial: { cont.yield(.partial($0)) },
            onFinal: { cont.yield(.final($0)) },
            onError: { [log] in log.error("reson8 ws error: \($0.localizedDescription, privacy: .public)") })
        client.start()

        let consume = Task { @MainActor [weak self] in
            for await kind in stream { self?.handle(kind) }
        }

        // Mic capture → converted 16 kHz Int16 chunks → WS.
        let captureURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reson8-spike-\(UUID().uuidString).wav")
        let recorder: DictationRecorder
        do {
            recorder = try DictationRecorder(url: captureURL, onLevel: nil,
                                             onChunk: { client.send($0) })
            try recorder.start()
        } catch {
            log.error("reson8 spike: mic start failed: \(error.localizedDescription, privacy: .public)")
            overlay.render(committed: "", volatile: "Mic unavailable")
            await client.finish()
            cont.finish()
            await consume.value
            try? await Task.sleep(for: .seconds(2))
            overlay.hide()
            return
        }

        try? await Task.sleep(for: .seconds(captureSeconds))

        _ = await recorder.stop()
        await client.finish()
        cont.finish()
        await consume.value
        try? FileManager.default.removeItem(at: captureURL)

        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        let firstMs = firstWordAt.map { Int($0 * 1000) } ?? -1
        log.info("""
            reson8-spike[\(self.captureSeconds, privacy: .public)s] \
            \(self.metrics.description, privacy: .public) \
            firstWordMs=\(firstMs, privacy: .public) totalMs=\(totalMs, privacy: .public)
            """)
        try? await Task.sleep(for: .seconds(2))
        overlay.hide()
    }

    private func handle(_ kind: ScriptKind) {
        switch kind {
        case .partial(let t): commit.update(partial: t)
        case .final(let t): commit.finalize(t)
        }
        let result = strategy.apply(committed: commit.committed, fullHypothesis: commit.fullHypothesis)
        if firstWordAt == nil, case .appended = result {
            firstWordAt = Date().timeIntervalSince(start)
        }
        metrics.record(result)
        overlay.render(committed: commit.committed, volatile: commit.volatileTail)
    }

    private func failEarly(_ message: String, detail: String) async {
        log.error("reson8 spike: \(detail, privacy: .public)")
        overlay.show()
        overlay.render(committed: "", volatile: message)
        try? await Task.sleep(for: .seconds(2))
        overlay.hide()
    }
}
#endif
```

- [ ] **Step 2: Commit (compiles as part of Task 6's app build)**

```bash
git add Amanuensis/Dictation/Streaming/Reson8SpikeHarness.swift
git commit -m "feat(dictation): add Reson8 Realtime DEBUG spike harness

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire the Reson8 spike into the Debug menu

**Files:**
- Modify: `Amanuensis/AmanuensisApp.swift`

**Interfaces:**
- Consumes: `Reson8SpikeHarness` (Task 5); `AppCoordinator.providers`, `AppCoordinator.keychain`; existing `KeystrokeDiffInserter`, `ClipboardAppendInserter`, `InsertionStrategy`.

- [ ] **Step 1: Thread the coordinator into the spike menu**

In `Amanuensis/AmanuensisApp.swift`, change the menu construction to pass the coordinator:

```swift
            #if DEBUG
            CommandMenu("Streaming Spike") {
                StreamingSpikeCommands(coordinator: coordinator)
            }
            #endif
```

- [ ] **Step 2: Add the Reson8 commands to `StreamingSpikeCommands`**

Update the `#if DEBUG private struct StreamingSpikeCommands: View` block: add the stored `coordinator`, two Reson8 buttons (after the existing simulated ones, separated by a `Divider`), and the `launchReson8` helper:

```swift
#if DEBUG
private struct StreamingSpikeCommands: View {
    let coordinator: AppCoordinator

    var body: some View {
        Button("Revisable × Clipboard (k=2)") {
            launch(.revisableSample, ClipboardAppendInserter(), k: 2)
        }
        Button("Revisable × Keystroke (k=2)") {
            launch(.revisableSample, KeystrokeDiffInserter(), k: 2)
        }
        Button("Revisable × Clipboard (k=3)") {
            launch(.revisableSample, ClipboardAppendInserter(), k: 3)
        }
        Button("Immutable × Clipboard (k=2)") {
            launch(.immutableSample, ClipboardAppendInserter(), k: 2)
        }
        Button("Immutable × Keystroke (k=2)") {
            launch(.immutableSample, KeystrokeDiffInserter(), k: 2)
        }
        Divider()
        Button("Reson8 Realtime (Keystroke)") {
            launchReson8(KeystrokeDiffInserter(), k: 3)
        }
        Button("Reson8 Realtime (Clipboard k=3)") {
            launchReson8(ClipboardAppendInserter(), k: 3)
        }
    }

    private func launch(_ script: SimulatedTranscriptScript, _ strategy: InsertionStrategy, k: Int) {
        let harness = StreamingSpikeHarness(script: script, strategy: strategy, stabilityCount: k)
        Task { await harness.run() }   // harness retained by the task until run() completes
    }

    private func launchReson8(_ strategy: InsertionStrategy, k: Int) {
        let harness = Reson8SpikeHarness(
            providers: coordinator.providers, keychain: coordinator.keychain,
            strategy: strategy, stabilityCount: k, captureSeconds: 20)
        Task { await harness.run() }   // harness retained by the task until run() completes
    }
}
#endif
```

- [ ] **Step 3: Build the app**

Run: `./scripts/xcode-build-helper.sh -project Amanuensis.xcodeproj -scheme Amanuensis -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full SPM suite (no regressions)**

Run: `swift test --disable-sandbox --package-path Packages/AudioPipeline`
Expected: PASS — all suites green, including the new `Reson8RealtimeURLBuilding`, `Reson8StreamDecoding`, and the extended `DictationWAVWriterTests`.

- [ ] **Step 5: Manual smoke test (the go/no-go)**

1. Launch the built app. Ensure a **Reson8 provider** exists in Settings with a valid API key (the same one the batch `reson8Prerecorded` path uses).
2. Open **TextEdit**, click into a document.
3. From the app menu bar: **Streaming Spike ▸ Reson8 Realtime (Keystroke)**. Focus TextEdit during the 3 s countdown.
4. Speak for ~20 s. Expect: words appear live in TextEdit; the overlay shows the volatile tail; a final flush lands at the end.
5. Check the log for the metrics line: `./scripts/log-helper.sh show --last 2m --info --predicate 'process == "Amanuensis"'` — look for `reson8-spike[...] appendedChars=… firstWordMs=… totalMs=…`, and confirm no `reson8 ws error` (other than a benign normal-closure on shutdown).

Record the observed first-word latency and transcription quality — that is the milestone's go/no-go.

- [ ] **Step 6: Commit**

```bash
git add Amanuensis/AmanuensisApp.swift
git commit -m "feat(dictation): wire Reson8 Realtime spike into the Debug menu

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Wire contract (§4a) → Tasks 1 (URL/config), 2 (decode), 3 (send/receive/flush/auth). ✓
- Pure core `Reson8RealtimeURL` + `Reson8StreamDecoder` in `AudioPipelineJobs`, SPM-tested (§4b, §4f) → Tasks 1–2. ✓
- Live `Reson8RealtimeClient` (§4c) → Task 3. ✓
- `onChunk` fan-out in `RecordingCore` (§4d) → Task 4. ✓
- DEBUG `Reson8SpikeHarness` with provider/key resolve, MainActor hop, mic→WS, fixed window, metrics (§4e) → Task 5. ✓
- Menu wiring, keystroke default + clipboard k=3 (§4e) → Task 6. ✓
- Error handling (§4g): no provider/key → `failEarly`; WS error → `onError` log; mic fail → overlay + abort; Post-Event via `TextInserter.requestPostEventAccess` → Tasks 5–6. ✓
- Success criteria (§5): live words in TextEdit, SPM tests green + app builds, metrics/latency judgment → Task 6 steps 3–5. ✓
- Non-goals (Turns, abstraction, Settings UI, coordinator changes, diarization/words, reconnect, manual stop) → not implemented. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; every run step shows an exact command + expected output. ✓

**Type consistency:** `Reson8RealtimeOptions` / `Reson8RealtimeURL.make` / `Reson8RealtimeURL.BuildError` (Tasks 1, 5); `Reson8StreamEvent` / `Reson8StreamDecoder.decode` (Tasks 2, 3); `Reson8RealtimeClient.init(url:apiKey:session:onPartial:onFinal:onError:)` / `start()` / `send(_:)` / `finish()` (Tasks 3, 5); `DictationWAVWriter.init(url:inputFormat:onLevel:onChunk:)` and `DictationRecorder.init(url:onLevel:onChunk:)` (Tasks 4, 5); `Reson8SpikeHarness.init(providers:keychain:strategy:stabilityCount:captureSeconds:)` (Tasks 5, 6); `ScriptKind.partial/.final`, `CommitController(stabilityCount:)`, `SpikeMetrics`, `SpikeOverlayPanel`, `TextInserter.requestPostEventAccess` reused from M1. All consistent across tasks. ✓
