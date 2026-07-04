import Darwin
import Testing
@testable import LocalTranscription

@Suite struct LocalModelSupportTests {
    // `isSupported` reads hardware truth (Apple Silicon has the Neural Engine).
    // Cross-check it against an INDEPENDENT signal — not the same
    // `hw.optional.arm64` sysctl (that would be circular): the process runs on
    // Apple Silicon iff it is native arm64, OR an x86_64 slice translated by
    // Rosetta (`sysctl.proc_translated == 1`). This holds on every host/slice
    // combo: arm64-native and x86_64-under-Rosetta (both Apple Silicon → true)
    // and native Intel (→ false), so the test is correct on any test runner.
    @Test func matchesHostHardware() {
        #if arch(arm64)
        let onAppleSilicon = true
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0
        let onAppleSilicon = ok && translated == 1
        #endif
        #expect(LocalModelSupport.isSupported == onAppleSilicon)
    }
}
