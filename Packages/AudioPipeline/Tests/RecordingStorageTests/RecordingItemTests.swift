import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingItemTests {
    @Test func validFixture_parsesMetadataAndFolderURL() throws {
        try withTempDirectory { baseURL in
            let metadata = makeMetadata(
                folderName: "fixture-2026-05-25",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 45
            )
            let folderURL = try makeRecordingFolderOnDisk(
                in: baseURL,
                name: metadata.folderName,
                metadata: metadata,
                tracks: ["mic.caf": 100, "system.caf": 200]
            )

            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.id == metadata.folderName)
            #expect(item.name == metadata.folderName)
            #expect(item.folderURL == folderURL)
            #expect(item.startedAt == metadata.startedAt)
            #expect(item.duration == 45)
        }
    }

    @Test func missingMetaJSON_returnsNil() throws {
        try withTempDirectory { baseURL in
            let folderURL = try makeRecordingFolderOnDisk(
                in: baseURL,
                name: "no-meta",
                metadata: nil,
                tracks: ["mic.caf": 10]
            )
            #expect(RecordingItem(folderURL: folderURL) == nil)
        }
    }

    @Test func corruptMetaJSON_returnsNil() throws {
        try withTempDirectory { baseURL in
            let folderURL = try makeRecordingFolderOnDisk(
                in: baseURL,
                name: "corrupt-meta",
                metadata: nil,
                tracks: [:]
            )
            let metaURL = folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
            try Data("not valid json {[".utf8).write(to: metaURL)

            #expect(RecordingItem(folderURL: folderURL) == nil)
        }
    }

    @Test func sizeBytes_sumsAllFilesInFolder() throws {
        try withTempDirectory { baseURL in
            let folderURL = try makeRecordingFolderOnDisk(
                in: baseURL,
                name: "size-test",
                metadata: makeMetadata(),
                tracks: ["mic.caf": 100, "system.caf": 250, "extra.bin": 50]
            )
            let item = try #require(RecordingItem(folderURL: folderURL))

            // meta.json bytes vary by content, so assert the sum is at least
            // the known track totals; precise size includes the meta.json.
            let knownTrackBytes: Int64 = 100 + 250 + 50
            #expect(item.sizeBytes >= knownTrackBytes)
            let metaBytes = try Data(
                contentsOf: folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
            ).count
            #expect(item.sizeBytes == knownTrackBytes + Int64(metaBytes))
        }
    }

    @Test(arguments: [
        (tracks: ["mic.caf": 10, "system.caf": 20], expected: "caf"),
        (tracks: ["mic.flac": 10, "system.flac": 20], expected: "flac"),
        (tracks: ["mic.caf": 10, "mic.flac": 20], expected: "caf + flac"),
        (tracks: [String: Int](), expected: ""),
    ])
    func formatSummary_reflectsPresentExtensions(
        tracks: [String: Int],
        expected: String
    ) throws {
        try withTempDirectory { baseURL in
            let folderURL = try makeRecordingFolderOnDisk(
                in: baseURL,
                name: "fmt-\(UUID().uuidString)",
                metadata: makeMetadata(),
                tracks: tracks
            )
            let item = try #require(RecordingItem(folderURL: folderURL))
            #expect(item.formatSummary == expected)
        }
    }
}
