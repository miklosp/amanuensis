import Testing
@testable import audio_pipeline

@Suite struct SmokeTests {
    @Test func testTargetIsWiredToTheAppModule() {
        // References an app type — proves @testable import links.
        #expect(AppSettings.OutputFormat.allCases.count == 3)
    }
}
