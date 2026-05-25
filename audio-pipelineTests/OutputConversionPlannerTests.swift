import AppSettings
import Foundation
import RecordingStorage
import Testing
@testable import audio_pipeline

@Suite struct OutputConversionPlannerTests {
    @Test func cafFormatReturnsEmptyPlan() throws {
        try withTempDirectory { base in
            let folder = try makePlannerFolder(in: base)

            let plan = OutputConversionPlanner.plan(folder: folder, format: .caf)

            #expect(plan.isEmpty)
        }
    }

    @Test func flacFormatPlansBothTracksAndRemovesSources() throws {
        try withTempDirectory { base in
            let folder = try makePlannerFolder(in: base)

            let plan = OutputConversionPlanner.plan(folder: folder, format: .flac)

            let expected = [
                OutputConversionPlanner.Task(
                    source: folder.micURL,
                    destination: folder.url.appending(path: "mic.flac", directoryHint: .notDirectory),
                    deleteSourceAfterExport: true
                ),
                OutputConversionPlanner.Task(
                    source: folder.systemURL,
                    destination: folder.url.appending(path: "system.flac", directoryHint: .notDirectory),
                    deleteSourceAfterExport: true
                ),
            ]
            #expect(plan == expected)
        }
    }

    @Test func bothFormatPlansBothTracksAndKeepsSources() throws {
        try withTempDirectory { base in
            let folder = try makePlannerFolder(in: base)

            let plan = OutputConversionPlanner.plan(folder: folder, format: .both)

            let expected = [
                OutputConversionPlanner.Task(
                    source: folder.micURL,
                    destination: folder.url.appending(path: "mic.flac", directoryHint: .notDirectory),
                    deleteSourceAfterExport: false
                ),
                OutputConversionPlanner.Task(
                    source: folder.systemURL,
                    destination: folder.url.appending(path: "system.flac", directoryHint: .notDirectory),
                    deleteSourceAfterExport: false
                ),
            ]
            #expect(plan == expected)
        }
    }

    @Test func missingSystemTrackIsSkipped() throws {
        try withTempDirectory { base in
            let folder = try makePlannerFolder(in: base, tracks: ["mic.caf"])

            let plan = OutputConversionPlanner.plan(folder: folder, format: .flac)

            #expect(plan == [
                OutputConversionPlanner.Task(
                    source: folder.micURL,
                    destination: folder.url.appending(path: "mic.flac", directoryHint: .notDirectory),
                    deleteSourceAfterExport: true
                ),
            ])
        }
    }

    @Test func missingMicTrackIsSkipped() throws {
        try withTempDirectory { base in
            let folder = try makePlannerFolder(in: base, tracks: ["system.caf"])

            let plan = OutputConversionPlanner.plan(folder: folder, format: .flac)

            #expect(plan == [
                OutputConversionPlanner.Task(
                    source: folder.systemURL,
                    destination: folder.url.appending(path: "system.flac", directoryHint: .notDirectory),
                    deleteSourceAfterExport: true
                ),
            ])
        }
    }
}
