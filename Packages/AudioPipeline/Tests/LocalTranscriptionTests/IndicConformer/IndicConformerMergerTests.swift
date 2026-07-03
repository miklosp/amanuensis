import Testing
@testable import LocalTranscription

@Test func tokenMergeDropsSharedSuffixPrefix() {
    let (ids, applied) = IndicConformerMerger.mergeTokens([[1, 2, 3, 4], [3, 4, 5, 6]])
    #expect(applied)
    #expect(ids == [1, 2, 3, 4, 5, 6])
}

@Test func tokenMergeConcatsWhenNoOverlap() {
    let (ids, applied) = IndicConformerMerger.mergeTokens([[1, 2], [7, 8]])
    #expect(!applied)
    #expect(ids == [1, 2, 7, 8])
}

@Test func textMergeDedupesOverlappingWords() {
    let text = IndicConformerMerger.mergeTexts(["ram gaya", "gaya ghar"])
    #expect(text == "ram gaya ghar")
}
