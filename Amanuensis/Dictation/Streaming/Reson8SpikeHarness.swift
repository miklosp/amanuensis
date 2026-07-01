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
    private var isStopping = false
    private var socketFailed = false

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
            onError: { [weak self] error in
                Task { @MainActor in self?.handleSocketError(error) }
            })
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
            isStopping = true
            await client.finish()
            cont.finish()
            await consume.value
            try? FileManager.default.removeItem(at: captureURL)
            try? await Task.sleep(for: .seconds(2))
            overlay.hide()
            return
        }

        let deadline = Date().addingTimeInterval(Double(captureSeconds))
        while Date() < deadline, !socketFailed {
            try? await Task.sleep(for: .milliseconds(100))
        }

        _ = await recorder.stop()
        isStopping = true
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

    private func handleSocketError(_ error: Error) {
        if isStopping { return }   // benign: our own finish()/cancel triggered this
        socketFailed = true
        log.error("reson8 ws error: \(error.localizedDescription, privacy: .public)")
        overlay.render(committed: commit.committed, volatile: "Reson8 connection failed")
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
