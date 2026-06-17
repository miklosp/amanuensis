import Testing
@testable import audio_pipeline

@Suite struct MainWindowViewTests {
    @Test func sidebarDestination_hasExpectedCases() {
        let all: Set<SidebarDestination> = [.recordings, .jobs]
        #expect(all.count == 2)
        #expect(all.contains(.recordings))
        #expect(all.contains(.jobs))
    }

    @Test func sidebarDestination_isHashable() {
        let dict: [SidebarDestination: String] = [
            .recordings: "Recordings",
            .jobs: "Jobs"
        ]
        #expect(dict[.recordings] == "Recordings")
        #expect(dict[.jobs] == "Jobs")
    }
}
