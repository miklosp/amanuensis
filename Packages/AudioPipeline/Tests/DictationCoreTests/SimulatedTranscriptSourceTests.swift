// SimulatedTranscriptSourceTests.swift
import Foundation
import Testing
@testable import DictationCore

@Suite struct SimulatedTranscriptSourceTests {
    @Test func replaysEventsInOrderWithInstantClock() async throws {
        let script = SimulatedTranscriptScript(name: "t", events: [
            .init(delayMs: 999, kind: .partial("a")),
            .init(delayMs: 999, kind: .partial("ab")),
            .init(delayMs: 999, kind: .final("ab.")),
        ])
        let source = SimulatedTranscriptSource(script: script, sleep: { _ in })  // instant

        let (stream, cont) = AsyncStream<String>.makeStream()
        try await source.transcribe(
            audioFile: URL(fileURLWithPath: "/dev/null"),
            onPartial: { cont.yield("P:" + $0) },
            onFinal: { cont.yield("F:" + $0) }
        )
        cont.finish()

        var got: [String] = []
        for await s in stream { got.append(s) }
        #expect(got == ["P:a", "P:ab", "F:ab."])
    }
}
