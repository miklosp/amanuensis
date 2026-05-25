import AVFoundation
import Foundation
import Testing
import RecordingCore

@Suite struct FLACExporterTests {
    @Test func export_resamplesToMono16kHzAndAboutOneThirdLength() async throws {
        try await withTempDirectory { tempURL in
            let source = tempURL.appending(path: "input.caf", directoryHint: .notDirectory)
            let destination = tempURL.appending(path: "output.flac", directoryHint: .notDirectory)

            let format = SyntheticAudio.stereo48kHz
            let inputFrames: AVAudioFrameCount = 48_000  // 1 second at 48 kHz
            try SyntheticAudio.writeCAF(to: source, format: format, frameCount: inputFrames)

            try await FLACExporter.export(from: source, to: destination)

            let readback = try AVAudioFile(forReading: destination)
            #expect(readback.processingFormat.sampleRate == 16_000)
            #expect(readback.processingFormat.channelCount == 1)

            // 48 kHz → 16 kHz is exactly 3:1; AVAudioConverter introduces a
            // small amount of trailing latency at end-of-stream. Allow a
            // generous tolerance — the assertion is "roughly one-third," not
            // "exact frame count."
            let expected = Int64(inputFrames) / 3
            let actual = readback.length
            #expect(abs(actual - expected) < 1000,
                    "expected ~\(expected) frames, got \(actual)")

            // Best-effort bit-depth check (spec §4.10).
            if let bits = readback.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int {
                #expect(bits == 16)
            }
        }
    }

    // Regression guards for the crash fixed in commit e775746: the previous
    // FLACExporter trapped uncatchably (CAVerboseAbort) on AVAudioFile.write
    // with a mismatched commonFormat. These tests just assert the export call
    // completes without throwing on edge-case inputs — output FLACs from
    // genuinely empty or sub-resample-window inputs may themselves be empty
    // and unreadable, which is acceptable (and arguably more correct than
    // silently writing a malformed file).

    @Test func export_emptyInput_completesWithoutCrashing() async throws {
        try await withTempDirectory { tempURL in
            let source = tempURL.appending(path: "empty.caf", directoryHint: .notDirectory)
            let destination = tempURL.appending(path: "empty.flac", directoryHint: .notDirectory)

            try SyntheticAudio.writeCAF(to: source, format: SyntheticAudio.stereo48kHz, frameCount: 0)
            try await FLACExporter.export(from: source, to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func export_veryShortInput_completesWithoutCrashing() async throws {
        try await withTempDirectory { tempURL in
            let source = tempURL.appending(path: "short.caf", directoryHint: .notDirectory)
            let destination = tempURL.appending(path: "short.flac", directoryHint: .notDirectory)

            try SyntheticAudio.writeCAF(to: source, format: SyntheticAudio.stereo48kHz, frameCount: 10)
            try await FLACExporter.export(from: source, to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
