import Foundation
import RecordingStorage

// Reusable RecordingMetadata fixtures.
extension RecordingMetadata.TrackMetadata {
    static let fixtureMic = RecordingMetadata.TrackMetadata(
        fileName: "mic.caf",
        sampleRate: 48_000,
        channelCount: 1,
        formatID: "alac",
        framesWritten: 96_000
    )

    static let fixtureSystem = RecordingMetadata.TrackMetadata(
        fileName: "system.caf",
        sampleRate: 48_000,
        channelCount: 2,
        formatID: "alac",
        framesWritten: 96_000
    )
}

// Builds a RecordingMetadata with sensible defaults; override any field.
func makeMetadata(
    folderName: String = "fixture-folder",
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    stoppedAt: Date? = Date(timeIntervalSince1970: 1_700_000_120),
    durationSeconds: Double? = 120,
    mic: RecordingMetadata.TrackMetadata? = .fixtureMic,
    system: RecordingMetadata.TrackMetadata? = .fixtureSystem,
    hostAppVersion: String? = "test",
    notes: String? = nil
) -> RecordingMetadata {
    RecordingMetadata(
        folderName: folderName,
        startedAt: startedAt,
        stoppedAt: stoppedAt,
        durationSeconds: durationSeconds,
        mic: mic,
        system: system,
        hostAppVersion: hostAppVersion,
        notes: notes
    )
}

// Creates a recording folder on disk under `baseURL`:
//   - the folder itself
//   - optional `meta.json` (skipped if `metadata == nil`)
//   - optional dummy track files keyed by filename, each filled with
//     `byteSize` zero bytes (so `RecordingItem.sizeBytes` has predictable
//     inputs).
//
// Returns the folder URL.
@discardableResult
func makeRecordingFolderOnDisk(
    in baseURL: URL,
    name: String,
    metadata: RecordingMetadata? = makeMetadata(),
    tracks: [String: Int] = ["mic.caf": 1024, "system.caf": 2048]
) throws -> URL {
    let folderURL = baseURL.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    if let metadata {
        try metadata.write(
            to: folderURL.appending(path: "meta.json", directoryHint: .notDirectory)
        )
    }

    for (filename, byteSize) in tracks {
        let data = Data(count: byteSize)
        try data.write(
            to: folderURL.appending(path: filename, directoryHint: .notDirectory)
        )
    }

    return folderURL
}
