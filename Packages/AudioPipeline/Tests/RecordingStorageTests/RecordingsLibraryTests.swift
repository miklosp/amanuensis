import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingsLibraryTests {
    @Test func refresh_listsValidFoldersSortedNewestFirst() throws {
        try withTempDirectory { baseURL in
            let older = makeMetadata(
                folderName: "older",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let newer = makeMetadata(
                folderName: "newer",
                startedAt: Date(timeIntervalSince1970: 1_700_100_000)
            )
            try makeRecordingFolderOnDisk(in: baseURL, name: "older", metadata: older)
            try makeRecordingFolderOnDisk(in: baseURL, name: "newer", metadata: newer)

            let library = RecordingsLibrary { baseURL }
            library.refresh()

            #expect(library.recordings.map(\.name) == ["newer", "older"])
        }
    }

    @Test func refresh_skipsNonDirectoryEntries() throws {
        try withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "valid", metadata: makeMetadata(folderName: "valid"))
            // A loose file at the top level should not appear as a recording.
            try Data("stray".utf8).write(
                to: baseURL.appending(path: "stray.txt", directoryHint: .notDirectory)
            )

            let library = RecordingsLibrary { baseURL }
            library.refresh()
            #expect(library.recordings.map(\.name) == ["valid"])
        }
    }

    @Test func refresh_skipsFoldersWithoutMetaJSON() throws {
        try withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "valid", metadata: makeMetadata(folderName: "valid"))
            try makeRecordingFolderOnDisk(in: baseURL, name: "no-meta", metadata: nil, tracks: ["mic.caf": 10])

            let library = RecordingsLibrary { baseURL }
            library.refresh()
            #expect(library.recordings.map(\.name) == ["valid"])
        }
    }

    @Test func refresh_missingBaseDirectory_yieldsEmptyList() {
        let baseURL = URL(
            filePath: "/tmp/audio-pipeline-tests-does-not-exist-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let library = RecordingsLibrary { baseURL }
        library.refresh()
        #expect(library.recordings.isEmpty)
    }

    // `delete(_:)` calls FileManager.trashItem and then refresh(). trashItem
    // requires access to the user Trash, which the Claude Code sandbox denies
    // for files under /tmp. We assert two things:
    //   (a) the always-true invariant: after delete()+refresh(), library state
    //       is consistent with disk state.
    //   (b) when the runtime *can* trash (probed once below), the folder is
    //       actually gone. This second assertion runs from a normal terminal
    //       and is skipped under the sandbox — leaves one recoverable item in
    //       the user Trash per run, acceptable for a temp folder.
    @Test func delete_keepsLibraryConsistentWithDisk() throws {
        try withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "doomed", metadata: makeMetadata(folderName: "doomed"))
            let library = RecordingsLibrary { baseURL }
            library.refresh()
            let target = try #require(library.recordings.first { $0.name == "doomed" })

            library.delete(target)

            let folderStillOnDisk = FileManager.default.fileExists(atPath: target.folderURL.path)
            let folderInList = library.recordings.contains { $0.name == "doomed" }
            #expect(folderStillOnDisk == folderInList)
        }
    }

    @Test(.enabled(if: Self.trashAvailable))
    func delete_movesFolderToTrash() throws {
        try withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "doomed-real", metadata: makeMetadata(folderName: "doomed-real"))
            let library = RecordingsLibrary { baseURL }
            library.refresh()
            let target = try #require(library.recordings.first { $0.name == "doomed-real" })

            library.delete(target)

            #expect(library.recordings.contains { $0.name == "doomed-real" } == false)
            #expect(FileManager.default.fileExists(atPath: target.folderURL.path) == false)
        }
    }

    // Probe once whether FileManager.trashItem works in this runtime. Inside
    // the Claude Code sandbox the user Trash is unreachable and trashItem
    // throws; from a normal shell it succeeds.
    nonisolated(unsafe) static let trashAvailable: Bool = {
        let probe = FileManager.default.temporaryDirectory.appending(
            path: "trash-probe-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        do {
            try FileManager.default.trashItem(at: probe, resultingItemURL: nil)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return false
        }
    }()
}
