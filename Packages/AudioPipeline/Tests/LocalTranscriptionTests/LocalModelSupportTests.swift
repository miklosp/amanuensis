import Testing
@testable import LocalTranscription

@Suite struct LocalModelSupportTests {
    // `isSupported` reads hardware truth via sysctl(hw.optional.arm64), so it is
    // `true` on Apple Silicon regardless of the executing slice — the native
    // arm64 slice AND an x86_64 slice under Rosetta both see Apple Silicon
    // hardware. This suite runs on Apple Silicon (dev + CI), so it must report
    // supported here. (Asserting `false` for the x86_64 slice would be wrong
    // under Rosetta, e.g. `swift test --arch x86_64` on an M-series Mac.)
    @Test func reportsSupportedOnAppleSiliconHost() {
        #expect(LocalModelSupport.isSupported == true)
    }
}
