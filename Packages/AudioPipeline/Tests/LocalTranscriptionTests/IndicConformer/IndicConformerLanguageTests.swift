import Testing
@testable import LocalTranscription

@Test func resolvesKnownCodesCaseAndWhitespaceInsensitive() {
    #expect(IndicConformerLanguage.resolved("hi") == .hi)
    #expect(IndicConformerLanguage.resolved("  HI ") == .hi)
    #expect(IndicConformerLanguage.resolved("bn") == .bn)
}

@Test func blankNilAndUnknownFallBackToHindi() {
    #expect(IndicConformerLanguage.resolved(nil) == .hi)
    #expect(IndicConformerLanguage.resolved("") == .hi)
    #expect(IndicConformerLanguage.resolved("en") == .hi)
    #expect(IndicConformerLanguage.resolved("hi-IN") == .hi)   // base-code fallback
}

@Test func postNetPackageMatchesCode() {
    #expect(IndicConformerLanguage.ta.postNetPackage == "indic_conformer_joint_post_net_ta.mlpackage")
}
