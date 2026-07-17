import Testing
import Foundation
import CoreMedia
import Speech
@testable import LocalTranscription

// Note: `@available(macOS 26, *)` goes on the `@Suite` struct's individual `@Test` funcs
// (and the helper they call), not on the struct itself — swift-testing's `@Suite` macro
// rejects an `@available`-marked type (https://github.com/swiftlang/swift-testing/issues/608).
@Suite struct AppleSpeechTimingsTests {
    /// Build an AttributedString whose runs carry the Speech time-range attribute,
    /// mimicking what SpeechTranscriber.Result.text yields.
    @available(macOS 26, *)
    private func timed(_ word: String, _ start: Double, _ end: Double) -> AttributedString {
        var s = AttributedString(word)
        s.audioTimeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1000),
            end: CMTime(seconds: end, preferredTimescale: 1000))
        return s
    }

    @Test
    @available(macOS 26, *)
    func extractsWordsWithSeconds() {
        var text = timed("Hello ", 0.0, 0.5)
        text.append(timed("world", 0.5, 1.0))
        let words = AppleSpeechEngine.timedWords(from: text)
        #expect(words.count == 2)
        #expect(words[0].text == "Hello ")
        #expect(abs(words[0].start - 0.0) < 0.001)
        #expect(abs(words[0].end - 0.5) < 0.001)
        #expect(words[1].text == "world")
        #expect(abs(words[1].start - 0.5) < 0.001)
    }

    @Test
    @available(macOS 26, *)
    func skipsRunsWithoutTimeRange() {
        var text = AttributedString("untimed ")   // no attribute
        text.append(timed("timed", 1.0, 1.5))
        let words = AppleSpeechEngine.timedWords(from: text)
        #expect(words.count == 1)
        #expect(words[0].text == "timed")
    }
}
