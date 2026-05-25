import Foundation
import RecordingStorage

// Builds a recording folder on disk containing the requested subset of track
// files (zero-byte placeholders) and returns a RecordingFolder pointing at it.
// Used by OutputConversionPlannerTests, which only cares which `.caf` files
// exist in the folder.
@discardableResult
func makePlannerFolder(
    in baseURL: URL,
    name: String = "fixture-folder",
    tracks: Set<String> = ["mic.caf", "system.caf"]
) throws -> RecordingFolder {
    let folderURL = baseURL.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

    for filename in tracks {
        try Data().write(
            to: folderURL.appending(path: filename, directoryHint: .notDirectory)
        )
    }

    return RecordingFolder(url: folderURL, name: name, startedAt: Date())
}
