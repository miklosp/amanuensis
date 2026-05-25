import AVFoundation
import Foundation

enum SyntheticAudio {
    // Standard 48 kHz stereo float format (matches the AVAudioEngine input
    // format we see on most Macs).
    static let stereo48kHz: AVAudioFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 2
    )!

    // 44.1 kHz mono float — used to exercise the writer with a different rate.
    static let mono44kHz: AVAudioFormat = AVAudioFormat(
        standardFormatWithSampleRate: 44_100,
        channels: 1
    )!

    // Build a PCM buffer with `frameCount` frames filled with a deterministic
    // ramp (so the buffer isn't all-zero — easier to spot accidental drops).
    static func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("AVAudioPCMBuffer allocation failed for \(format)")
        }
        buffer.frameLength = frameCount

        let channelCount = Int(format.channelCount)
        guard let channelData = buffer.floatChannelData else {
            // Non-float formats aren't expected in tests; the standard formats
            // above are always float32 interleaved.
            fatalError("floatChannelData unavailable for \(format)")
        }
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<Int(frameCount) {
                samples[frame] = Float(frame % 2048) / 2048.0  // 0..<1 ramp
            }
        }
        return buffer
    }

    // Write a synthetic `.caf` at `url` containing `frameCount` frames of the
    // given format. Uses linear PCM rather than ALAC: ALAC has minimum-packet
    // alignment requirements that make 0-frame or very-short writes produce
    // CAFs that ExtAudioFile can't re-open, which would break the empty /
    // very-short FLACExporter test cases. PCM has no such constraint and is
    // equally valid input for AVAudioFile/AVAudioConverter.
    @discardableResult
    static func writeCAF(
        to url: URL,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioFile {
        // AVAudioFile only supports interleaved PCM on disk regardless of the
        // in-memory format, so don't set AVLinearPCMIsNonInterleaved.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        if frameCount > 0 {
            let buffer = makeBuffer(format: format, frameCount: frameCount)
            try file.write(from: buffer)
        }
        return file
    }
}
