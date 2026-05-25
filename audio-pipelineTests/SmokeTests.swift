import Testing
@testable import audio_pipeline

@Suite struct SmokeTests {
    @Test func testTargetIsWiredToTheAppModule() {
        // References an app-target type — proves @testable import links.
        let _: AppCoordinator.Status = .idle
        #expect(Bool(true))
    }
}
