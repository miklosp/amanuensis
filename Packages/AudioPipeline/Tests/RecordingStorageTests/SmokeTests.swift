import Foundation
import Testing
import RecordingStorage

// Placeholder test that asserts the RecordingStorage module compiles into a
// test target. Real tests will replace this per the test-coverage spec
// (docs/superpowers/specs/2026-05-22-test-coverage-design.md).
@Test func folderNamingProducesShellFriendlyStamp() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "audio-pipeline-test-\(UUID().uuidString)",
                   directoryHint: .isDirectory)
    let store = RecordingStore(baseURL: tmp)
    let folder = try store.makeRecordingFolder(
        label: nil,
        date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(folder.name.contains(":") == false)
    try? FileManager.default.removeItem(at: tmp)
}
