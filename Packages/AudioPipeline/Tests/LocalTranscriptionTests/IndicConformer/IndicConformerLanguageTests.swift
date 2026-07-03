import Testing
@testable import LocalTranscription

@Test func resolvesKnownCodesCaseAndWhitespaceInsensitive() {
    #expect(IndicConformerLanguage.supported("hi") == .hi)
    #expect(IndicConformerLanguage.supported("  HI ") == .hi)
    #expect(IndicConformerLanguage.supported("bn") == .bn)
    #expect(IndicConformerLanguage.supported("hi-IN") == .hi)   // region-qualified still resolves
}

@Test func blankNilAndUnsupportedReturnNil() {
    #expect(IndicConformerLanguage.supported(nil) == nil)
    #expect(IndicConformerLanguage.supported("") == nil)
    #expect(IndicConformerLanguage.supported("en") == nil)     // no silent fallback to Hindi
    #expect(IndicConformerLanguage.supported("ja") == nil)
}

@Test func postNetPackageMatchesCode() {
    #expect(IndicConformerLanguage.ta.postNetPackage == "indic_conformer_joint_post_net_ta.mlpackage")
}
