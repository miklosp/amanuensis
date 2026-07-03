import Testing
@testable import Amanuensis

@Suite struct MainWindowViewTests {
    /// Enumerates every `SidebarDestination` via the compiler-synthesized
    /// `allCases`. The `switch` has no `default`, so adding a case makes this
    /// test fail to compile until the case is handled here — the tripwire that
    /// stops this enumeration from silently going stale, as the old
    /// hardcoded two-case version did.
    @Test func everyDestinationIsEnumerated() {
        for destination in SidebarDestination.allCases {
            switch destination {
            case .dictation, .recordings, .jobs, .providers, .localModels, .logs:
                break
            }
        }
        #expect(SidebarDestination.allCases.count == 6)
    }

    @Test func destinationsAreDistinctAndHashable() {
        // Placing them in a Set proves Hashable conformance (the sidebar
        // selection binding relies on it) and confirms `allCases` has no
        // accidental duplicates.
        let all = SidebarDestination.allCases
        #expect(Set(all).count == all.count)
    }
}
