import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingTitleTests {
    @Test func itemName_prefersTitleOverFolderName() throws {
        try withTempDirectory { baseURL in
            let meta = makeMetadata(folderName: "2026-07-02-1200", title: "Team sync")
            let folderURL = try makeRecordingFolderOnDisk(in: baseURL, name: meta.folderName, metadata: meta)
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.id == "2026-07-02-1200")
            #expect(item.name == "Team sync")
        }
    }

    @Test func itemName_fallsBackToFolderName_whenTitleBlank() throws {
        try withTempDirectory { baseURL in
            let meta = makeMetadata(folderName: "2026-07-02-1200", title: "   ")
            let folderURL = try makeRecordingFolderOnDisk(in: baseURL, name: meta.folderName, metadata: meta)
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.name == "2026-07-02-1200")
        }
    }

    @Test func legacyMetaWithoutTitleKey_stillDecodes() throws {
        try withTempDirectory { baseURL in
            let folderURL = baseURL.appending(path: "legacy", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let json = #"{"schemaVersion":1,"folderName":"legacy","startedAt":"2023-11-14T22:13:20Z"}"#
            try Data(json.utf8).write(
                to: folderURL.appending(path: "meta.json", directoryHint: .notDirectory))
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.name == "legacy")
        }
    }

    @Test func rename_writesTitleAndUpdatesName() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "rec1", metadata: makeMetadata(folderName: "rec1"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let item = try #require(library.recordings.first { $0.id == "rec1" })

            await library.rename(item, to: "My recording")

            #expect(library.recordings.first { $0.id == "rec1" }?.name == "My recording")
            let reread = try #require(RecordingItem(folderURL: item.folderURL))
            #expect(reread.name == "My recording")
        }
    }

    @Test func rename_toBlank_clearsTitleBackToFolderName() async throws {
        try await withTempDirectory { baseURL in
            try makeRecordingFolderOnDisk(in: baseURL, name: "rec2", metadata: makeMetadata(folderName: "rec2", title: "Old"))
            let library = RecordingsLibrary { baseURL }
            await library.refresh()
            let item = try #require(library.recordings.first { $0.id == "rec2" })

            await library.rename(item, to: "   ")

            #expect(library.recordings.first { $0.id == "rec2" }?.name == "rec2")
        }
    }
}
