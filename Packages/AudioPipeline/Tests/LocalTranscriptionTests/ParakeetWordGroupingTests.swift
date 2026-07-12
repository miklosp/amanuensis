import Testing
import Foundation
import FluidAudio
@testable import LocalTranscription

private func tk(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
    TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1)
}

@Test func groupsSubwordTokensIntoOneWord() {
    let words = groupParakeetWords([tk("▁hel", 0, 0.2), tk("lo", 0.2, 0.4)])
    #expect(words == [TimedWord(text: " hello", start: 0, end: 0.4)])
}

@Test func groupsMultipleWordsSpanningTimes() {
    let words = groupParakeetWords([tk("▁the", 0, 0.1), tk("▁cat", 0.1, 0.3), tk("▁sat", 0.3, 0.5)])
    #expect(words == [
        TimedWord(text: " the", start: 0, end: 0.1),
        TimedWord(text: " cat", start: 0.1, end: 0.3),
        TimedWord(text: " sat", start: 0.3, end: 0.5),
    ])
}

@Test func handlesAsciiSpaceBoundary() {
    let words = groupParakeetWords([tk(" hi", 0, 0.1), tk(" there", 0.1, 0.2)])
    #expect(words.map(\.text) == [" hi", " there"])
}

@Test func skipsSpecialAndEmptyTokens() {
    let words = groupParakeetWords([tk("<blank>", 0, 0), tk("▁ok", 0.1, 0.2), tk("", 0.2, 0.2), tk("<pad>", 0.2, 0.2)])
    #expect(words == [TimedWord(text: " ok", start: 0.1, end: 0.2)])
}

@Test func emptyInputYieldsEmpty() {
    #expect(groupParakeetWords([]).isEmpty)
}

@Test func firstTokenWithoutBoundaryStartsAWord() {   // defensive
    let words = groupParakeetWords([tk("lo", 0, 0.1), tk("▁world", 0.1, 0.3)])
    #expect(words.map(\.text) == [" lo", " world"])
}

@Test func joinedTextReconstructsTranscript() {
    let words = groupParakeetWords([tk("▁the", 0, 0.1), tk("▁cat", 0.1, 0.3)])
    let plain = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    #expect(plain == "the cat")
}
