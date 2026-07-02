// TranscriptionSourceTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Test func nilProviderIsNone() {
    #expect(TranscriptionSource(providerID: nil) == .none)
}
@Test func localSentinelIsLocal() {
    #expect(TranscriptionSource(providerID: Provider.localID) == .local)
}
@Test func otherUUIDIsProvider() {
    let id = UUID()
    #expect(TranscriptionSource(providerID: id) == .provider(id))
}
@Test func providerIDRoundTrips() {
    #expect(TranscriptionSource.none.providerID == nil)
    #expect(TranscriptionSource.local.providerID == Provider.localID)
    let id = UUID()
    #expect(TranscriptionSource.provider(id).providerID == id)
}
@Test func localSentinelIsStable() {
    // A fixed, reserved constant — must never change (persisted on disk).
    #expect(Provider.localID.uuidString == "10CA110C-0000-0000-0000-000000000000")
}
