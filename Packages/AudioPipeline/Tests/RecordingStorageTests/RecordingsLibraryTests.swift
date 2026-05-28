import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingsLibraryTests {
    @Test func refresh_listsValidFoldersSortedNewestFirst() async throws {
        try await withTempDirectory { baseURL in
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
            await library.refresh()

            #expect(library.recordings.map(\.name) == ["newer", "older"])
        }
    }

    @Test func refresh_skipsNonDirectoryEntries() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "valid", metadata: makeMetadata(folderName: "valid"))
            try Data("stray".utf8).write(
                to: baseURL.appending(path: "stray.txt", directoryHint: .notDirectory)
            )

            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            #expect(library.recordings.map(\.name) == ["valid"])
        }
    }

    @Test func refresh_skipsFoldersWithoutMetaJSON() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "valid", metadata: makeMetadata(folderName: "valid"))
            try makeRecordingFolderOnDisk(in: baseURL, name: "no-meta", metadata: nil, tracks: ["mic.caf": 10])

            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            #expect(library.recordings.map(\.name) == ["valid"])
        }
    }

    @Test func refresh_missingBaseDirectory_yieldsEmptyList() async {
        let baseURL = URL(
            filePath: "/tmp/audio-pipeline-tests-does-not-exist-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let library = RecordingsLibrary { baseURL }
        await library.refresh()
        #expect(library.recordings.isEmpty)
    }

    @Test func delete_keepsLibraryConsistentWithDisk() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "doomed", metadata: makeMetadata(folderName: "doomed"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let target = try #require(library.recordings.first { $0.name == "doomed" })

            await library.delete(target)

            let folderStillOnDisk = FileManager.default.fileExists(atPath: target.folderURL.path)
            let folderInList = library.recordings.contains { $0.name == "doomed" }
            #expect(folderStillOnDisk == folderInList)
        }
    }

    @Test(.enabled(if: Self.trashAvailable))
    func delete_movesFolderToTrash() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "doomed-real", metadata: makeMetadata(folderName: "doomed-real"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let target = try #require(library.recordings.first { $0.name == "doomed-real" })

            await library.delete(target)

            #expect(library.recordings.contains { $0.name == "doomed-real" } == false)
            #expect(FileManager.default.fileExists(atPath: target.folderURL.path) == false)
        }
    }

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
