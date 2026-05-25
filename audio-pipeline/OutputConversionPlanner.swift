import AppSettings
import Foundation
import RecordingStorage

// Pure plan of post-recording conversion work derived from a recording folder
// and the user's output-format preference. The driver (`AppCoordinator`)
// executes the returned tasks via `FLACExporter`; the planner itself does no
// audio work and only consults the file system to skip tracks that weren't
// captured.
enum OutputConversionPlanner {
    struct Task: Equatable {
        let source: URL
        let destination: URL
        let deleteSourceAfterExport: Bool
    }

    static func plan(
        folder: RecordingFolder,
        format: AppSettings.OutputFormat
    ) -> [Task] {
        guard format != .caf else { return [] }
        let deleteSource = (format == .flac)
        let tracks: [(caf: URL, flac: URL)] = [
            (folder.micURL,
             folder.url.appending(path: "mic.flac", directoryHint: .notDirectory)),
            (folder.systemURL,
             folder.url.appending(path: "system.flac", directoryHint: .notDirectory)),
        ]
        return tracks
            .filter { FileManager.default.fileExists(atPath: $0.caf.path) }
            .map {
                Task(source: $0.caf,
                     destination: $0.flac,
                     deleteSourceAfterExport: deleteSource)
            }
    }
}
