import Testing
@testable import LocalTranscription

@Test func tokenMergeDropsSharedSuffixPrefix() {
    let ids = IndicConformerMerger.mergeTokens([[1, 2, 3, 4], [3, 4, 5, 6]])
    #expect(ids == [1, 2, 3, 4, 5, 6])
}

@Test func tokenMergeConcatsWhenNoOverlap() {
    let ids = IndicConformerMerger.mergeTokens([[1, 2], [7, 8]])
    #expect(ids == [1, 2, 7, 8])
}

// Divergent join: shared words [7,8], then chunk A truncates the boundary word
// to 9 while chunk B has the full form 10. Exact suffix/prefix can't align, so
// the shared words must not be duplicated — the later chunk's version wins.
@Test func tokenMergeDropsDivergentTrailingWord() {
    let ids = IndicConformerMerger.mergeTokens([[5, 6, 7, 8, 9], [7, 8, 10, 11]])
    #expect(ids == [5, 6, 7, 8, 10, 11])
}

// Both-side divergence (the ml case): shared run [20,21,22]; chunk A ends with a
// divergent trailing token (99), chunk B begins with hallucinated garbage
// (77,78) before re-decoding the run and ends with a variant (88). The garbage
// must be dropped and the run must not be duplicated.
@Test func tokenMergeAlignsThroughLeadingGarbageAndDivergentTail() {
    let ids = IndicConformerMerger.mergeTokens([[10, 11, 20, 21, 22, 99], [77, 78, 20, 21, 22, 88]])
    #expect(ids == [10, 11, 20, 21, 22, 88])
}
