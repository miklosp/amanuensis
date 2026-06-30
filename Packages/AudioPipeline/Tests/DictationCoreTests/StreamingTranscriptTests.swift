import Foundation
import Testing
@testable import DictationCore

@Suite struct StreamingTranscriptTests {
    @Test func scriptCodableRoundTrip() throws {
        let script = SimulatedTranscriptScript(name: "t", events: [
            .init(delayMs: 10, kind: .partial("a")),
            .init(delayMs: 20, kind: .final("a.")),
        ])
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(SimulatedTranscriptScript.self, from: data)
        #expect(decoded == script)
    }

    @Test func revisableFixtureHasMidUtteranceRevision() {
        // Some partial revises a word that an earlier partial had as a stable prefix.
        let texts = SimulatedTranscriptScript.revisableSample.events.compactMap { ev -> String? in
            if case .partial(let t) = ev.kind { return t } else { return nil }
        }
        // Later partial is NOT a prefix-extension of an earlier one (a real revision).
        let revised = zip(texts, texts.dropFirst()).contains { !$0.1.hasPrefix($0.0) }
        #expect(revised)
    }

    @Test func immutableFixtureIsMonotonic() {
        let texts = SimulatedTranscriptScript.immutableSample.events.compactMap { ev -> String? in
            if case .partial(let t) = ev.kind { return t } else { return nil }
        }
        let monotonic = zip(texts, texts.dropFirst()).allSatisfy { $0.1.hasPrefix($0.0) }
        #expect(monotonic)
    }
}
