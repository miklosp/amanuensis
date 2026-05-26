import AVFoundation
import Foundation
import Testing
import RecordingCore

@Suite struct CombinedFLACExporterTests {
    @Test func combine_micAndSystem_producesMono16kHzFLAC() async throws {
        try await withTempDirectory { tempURL in
            let mic = tempURL.appending(path: "mic.caf", directoryHint: .notDirectory)
            let sys = tempURL.appending(path: "system.caf", directoryHint: .notDirectory)
            let dest = tempURL.appending(path: "combined.flac", directoryHint: .notDirectory)

            let format = SyntheticAudio.stereo48kHz
            let inputFrames: AVAudioFrameCount = 48_000  // 1 second at 48 kHz
            try SyntheticAudio.writeCAF(to: mic, format: format, frameCount: inputFrames)
            try SyntheticAudio.writeCAF(to: sys, format: format, frameCount: inputFrames)

            try await CombinedFLACExporter.combine(mic: mic, system: sys, to: dest)

            let readback = try AVAudioFile(forReading: dest)
            #expect(readback.processingFormat.sampleRate == 16_000)
            #expect(readback.processingFormat.channelCount == 1)

            // 48 kHz → 16 kHz is 3:1; AVAudioConverter introduces a small
            // amount of trailing latency at end-of-stream. Allow a generous
            // tolerance — the assertion is "roughly one-third," not "exact."
            let expected = Int64(inputFrames) / 3
            let actual = readback.length
            #expect(abs(actual - expected) < 1000,
                    "expected ~\(expected) frames, got \(actual)")

            if let bits = readback.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int {
                #expect(bits == 16)
            }
        }
    }

    @Test func combine_systemNil_producesMicOnlyFLAC() async throws {
        try await withTempDirectory { tempURL in
            let mic = tempURL.appending(path: "mic.caf", directoryHint: .notDirectory)
            let dest = tempURL.appending(path: "combined.flac", directoryHint: .notDirectory)

            try SyntheticAudio.writeCAF(
                to: mic, format: SyntheticAudio.stereo48kHz, frameCount: 48_000
            )

            try await CombinedFLACExporter.combine(mic: mic, system: nil, to: dest)

            let readback = try AVAudioFile(forReading: dest)
            #expect(readback.processingFormat.sampleRate == 16_000)
            #expect(readback.processingFormat.channelCount == 1)
            #expect(readback.length > 0)
        }
    }

    @Test func combine_systemMissing_treatsAsMicOnly() async throws {
        try await withTempDirectory { tempURL in
            let mic = tempURL.appending(path: "mic.caf", directoryHint: .notDirectory)
            let absentSys = tempURL.appending(path: "missing.caf", directoryHint: .notDirectory)
            let dest = tempURL.appending(path: "combined.flac", directoryHint: .notDirectory)

            try SyntheticAudio.writeCAF(
                to: mic, format: SyntheticAudio.stereo48kHz, frameCount: 48_000
            )
            // absentSys is never written — AVAudioFile(forReading:) will throw,
            // and the exporter should swallow that and fall back to mic-only.

            try await CombinedFLACExporter.combine(mic: mic, system: absentSys, to: dest)

            let readback = try AVAudioFile(forReading: dest)
            #expect(readback.processingFormat.sampleRate == 16_000)
            #expect(readback.processingFormat.channelCount == 1)
            #expect(readback.length > 0)
        }
    }

    @Test func combine_emptyMic_completesWithoutCrashing() async throws {
        try await withTempDirectory { tempURL in
            let mic = tempURL.appending(path: "mic.caf", directoryHint: .notDirectory)
            let sys = tempURL.appending(path: "system.caf", directoryHint: .notDirectory)
            let dest = tempURL.appending(path: "combined.flac", directoryHint: .notDirectory)

            try SyntheticAudio.writeCAF(
                to: mic, format: SyntheticAudio.stereo48kHz, frameCount: 0
            )
            try SyntheticAudio.writeCAF(
                to: sys, format: SyntheticAudio.stereo48kHz, frameCount: 4_800
            )

            try await CombinedFLACExporter.combine(mic: mic, system: sys, to: dest)
            #expect(FileManager.default.fileExists(atPath: dest.path))
        }
    }
}
