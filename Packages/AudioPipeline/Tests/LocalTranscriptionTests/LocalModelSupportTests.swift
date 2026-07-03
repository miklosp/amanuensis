import Testing
@testable import LocalTranscription

@Suite struct LocalModelSupportTests {
    // Ties the runtime sysctl result to the architecture the test binary was
    // compiled for: Apple Silicon (arm64 slice) supports local models; Intel
    // (x86_64 slice) does not. Deterministic on any native run.
    @Test func matchesRunningArchitecture() {
        #if arch(arm64)
        #expect(LocalModelSupport.isSupported == true)
        #else
        #expect(LocalModelSupport.isSupported == false)
        #endif
    }
}
