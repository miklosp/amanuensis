#if DEBUG
import Foundation
import DictationCore
import os

struct SpikeMetrics: CustomStringConvertible {
    var appendedChars = 0
    var revisedEvents = 0
    var backspaces = 0
    var revisionMisses = 0

    mutating func record(_ r: InsertionResult) {
        switch r {
        case .appended(let n): appendedChars += n
        case .revised(let b, let n): revisedEvents += 1; backspaces += b; appendedChars += n
        case .revisionMiss: revisionMisses += 1
        case .noop: break
        }
    }

    var description: String {
        "appendedChars=\(appendedChars) revisedEvents=\(revisedEvents) "
        + "backspaces=\(backspaces) revisionMisses=\(revisionMisses)"
    }
}

/// DEBUG-only driver: replays a script through the commit window into the frontmost
/// app via a chosen strategy, showing the volatile tail in an overlay and logging metrics.
@MainActor
final class StreamingSpikeHarness {
    private let script: SimulatedTranscriptScript
    private let strategy: InsertionStrategy
    private let stabilityCount: Int
    private let overlay = SpikeOverlayPanel()
    private let log = Logger(subsystem: "work.miklos.amanuensis", category: "spike")

    init(script: SimulatedTranscriptScript, strategy: InsertionStrategy, stabilityCount: Int = 2) {
        self.script = script
        self.strategy = strategy
        self.stabilityCount = stabilityCount
    }

    func run() async {
        _ = TextInserter.requestPostEventAccess()
        overlay.show()
        strategy.reset()
        var commit = CommitController(stabilityCount: stabilityCount)
        var metrics = SpikeMetrics()

        // Countdown so the developer can focus a target app (e.g. TextEdit).
        for n in stride(from: 3, through: 1, by: -1) {
            overlay.render(committed: "", volatile: "Starting in \(n)…")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let start = Date()
        var firstWordAt: TimeInterval?

        let source = SimulatedTranscriptSource(script: script)
        let (stream, cont) = AsyncStream<ScriptKind>.makeStream()
        let task = Task.detached {
            try? await source.transcribe(
                audioFile: URL(fileURLWithPath: "/dev/null"),
                onPartial: { cont.yield(.partial($0)) },
                onFinal: { cont.yield(.final($0)) })
            cont.finish()
        }

        for await kind in stream {           // consumed on MainActor, in order
            switch kind {
            case .partial(let t): commit.update(partial: t)
            case .final(let t): commit.finalize(t)
            }
            // Idempotent: each strategy diffs against its own last-applied target, so
            // calling once per event is correct for both clipboard and keystroke.
            let result = strategy.apply(
                committed: commit.committed, fullHypothesis: commit.fullHypothesis)
            if firstWordAt == nil, case .appended = result {
                firstWordAt = Date().timeIntervalSince(start)
            }
            metrics.record(result)
            overlay.render(committed: commit.committed, volatile: commit.volatileTail)
        }
        _ = await task.value

        let totalMs = Int(Date().timeIntervalSince(start) * 1000)
        let firstMs = firstWordAt.map { Int($0 * 1000) } ?? -1
        log.info("""
            spike[\(self.script.name, privacy: .public) k=\(self.stabilityCount)] \
            \(metrics.description, privacy: .public) \
            firstWordMs=\(firstMs, privacy: .public) totalMs=\(totalMs, privacy: .public)
            """)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        overlay.hide()
    }
}
#endif
