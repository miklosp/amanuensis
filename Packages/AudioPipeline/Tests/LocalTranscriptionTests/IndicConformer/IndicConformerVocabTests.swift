import Foundation
import Testing
@testable import LocalTranscription

@Test func decodeSkipsBlankAndMapsSentencePieceSpace() {
    var tokens = [String](repeating: "", count: 300)
    tokens[10] = "\u{2581}na"; tokens[11] = "ma"; tokens[12] = "\u{2581}ste"
    let vocab = IndicConformerVocab(tokens: [.hi: tokens])
    // blank(256) between tokens is ignored
    let text = vocab.decode([10, 11, 256, 12], language: .hi)
    #expect(text == "nama ste")
}

@Test func decodeIgnoresOutOfRangeIds() {
    var tokens = [String](repeating: "", count: 300)
    tokens[5] = "\u{2581}ok"
    let vocab = IndicConformerVocab(tokens: [.hi: tokens])
    #expect(vocab.decode([5, 9999, -1], language: .hi) == "ok")
}

@Test func decodeUnknownLanguageIsEmpty() {
    let vocab = IndicConformerVocab(tokens: [:])
    #expect(vocab.decode([1, 2, 3], language: .ta) == "")
}
