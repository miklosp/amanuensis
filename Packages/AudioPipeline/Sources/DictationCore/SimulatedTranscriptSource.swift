// SimulatedTranscriptSource.swift
import Foundation

/// A `DictationTranscriber` that ignores audio and replays a hand-authored script,
/// honoring per-event delays. Sleep is injected so tests run instantly.
public struct SimulatedTranscriptSource: DictationTranscriber {
    public let script: SimulatedTranscriptScript
    public let sleep: @Sendable (UInt64) async -> Void

    public init(
        script: SimulatedTranscriptScript,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.script = script
        self.sleep = sleep
    }

    public func transcribe(
        audioFile: URL,
        onPartial: @Sendable (String) -> Void,
        onFinal: @Sendable (String) -> Void
    ) async throws {
        for event in script.events {
            await sleep(UInt64(max(0, event.delayMs)) * 1_000_000)
            switch event.kind {
            case .partial(let t): onPartial(t)
            case .final(let t): onFinal(t)
            }
        }
    }
}
