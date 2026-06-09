import AVFoundation
import Foundation
import Testing
@testable import AudioPipelineJobs

// Writes a `seconds`-long 16 kHz mono sine to a 16-bit WAV and returns its URL,
// to exercise the real encoder (AVFoundation works in this SPM test sandbox —
// the CombinedFLACExporter suite relies on the same).
private func writeSineWAV(seconds: Double) throws -> URL {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                            channels: 1, interleaved: false)!
    let frames = AVAudioFrameCount(16_000 * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    let ptr = buf.floatChannelData![0]
    for i in 0..<Int(frames) { ptr[i] = sin(Float(i) * 0.1) * 0.5 }

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sine-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buf)
    return url
}

private func fileSize(_ url: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? Int) ?? -1
}

@Suite struct AudioCompressorBehavior {
    @Test func compressToM4A_producesSmallerDecodableFile() async throws {
        let wav = try writeSineWAV(seconds: 2.0)
        let m4a = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: m4a) }

        try await AudioCompressor.compressToM4A(source: wav, to: m4a)

        #expect(FileManager.default.fileExists(atPath: m4a.path))
        let inSize = fileSize(wav)
        let outSize = fileSize(m4a)
        #expect(outSize > 0)
        #expect(outSize < inSize)

        // Re-openable as audio at the requested rate, ~2 s long.
        let decoded = try AVAudioFile(forReading: m4a)
        #expect(decoded.fileFormat.sampleRate == 16_000)
        let duration = Double(decoded.length) / decoded.fileFormat.sampleRate
        #expect(abs(duration - 2.0) < 0.5)
    }
}
