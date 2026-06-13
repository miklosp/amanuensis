import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingStoreTests {
    @Test func folderName_isISO8601WithColonsStripped() throws {
        try withTempDirectory { baseURL in
            let store = RecordingStore(baseURL: baseURL)
            // 2023-11-14T22:13:20Z — fixed UTC instant.
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let folder = try store.makeRecordingFolder(label: nil, date: date)

            #expect(folder.name.contains(":") == false)
            #expect(folder.name == "2023-11-14T22-13-20Z")
            #expect(folder.startedAt == date)

            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDir))
            #expect(isDir.boolValue)
        }
    }

    @Test func folderName_appendsSafeLabel() throws {
        try withTempDirectory { baseURL in
            let store = RecordingStore(baseURL: baseURL)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let folder = try store.makeRecordingFolder(label: "meeting/intro", date: date)

            // Slashes in labels are replaced with `-` to keep the folder name a
            // single path component.
            #expect(folder.name == "2023-11-14T22-13-20Z_meeting-intro")
        }
    }

    @Test func folderName_emptyLabel_treatedAsNoLabel() throws {
        try withTempDirectory { baseURL in
            let store = RecordingStore(baseURL: baseURL)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let folder = try store.makeRecordingFolder(label: "", date: date)

            #expect(folder.name == "2023-11-14T22-13-20Z")
        }
    }

    @Test func makeRecordingFolder_sameSecond_doesNotCollide() throws {
        try withTempDirectory { baseURL in
            let store = RecordingStore(baseURL: baseURL)
            // Two recordings started at the identical whole-second instant must
            // land in distinct folders, not overwrite each other.
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let first = try store.makeRecordingFolder(label: nil, date: date)
            let second = try store.makeRecordingFolder(label: nil, date: date)

            #expect(first.name == "2023-11-14T22-13-20Z")
            #expect(second.name == "2023-11-14T22-13-20Z-2")
            #expect(first.url != second.url)

            for folder in [first, second] {
                var isDir: ObjCBool = false
                #expect(FileManager.default.fileExists(atPath: folder.url.path, isDirectory: &isDir))
                #expect(isDir.boolValue)
            }
        }
    }

    @Test func recordingFolderURLs_pointAtExpectedFiles() {
        let baseURL = URL(filePath: "/tmp/audio-pipeline-tests-url-only", directoryHint: .isDirectory)
        let folder = RecordingFolder(
            url: baseURL.appending(path: "fixture", directoryHint: .isDirectory),
            name: "fixture",
            startedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(folder.micURL.lastPathComponent == "mic.caf")
        #expect(folder.systemURL.lastPathComponent == "system.caf")
        #expect(folder.metadataURL.lastPathComponent == "meta.json")
        #expect(folder.micURL.deletingLastPathComponent() == folder.url)
        #expect(folder.systemURL.deletingLastPathComponent() == folder.url)
        #expect(folder.metadataURL.deletingLastPathComponent() == folder.url)
    }
}
