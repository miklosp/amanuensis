import AVFoundation

/// Writes in-memory 16 kHz mono Float samples to a WAV file the local
/// transcription engines can read. Static + nonisolated so the controller can
/// call it off the main actor. Mirrors DictationWAVWriter's Int16/16 kHz output
/// format and its 4-arg AVAudioFile init (a 2-arg init leaves processingFormat
/// float32/deinterleaved and aborts on an Int16 write).
public enum SegmentAudioWriter {
    public enum WriterError: Error, Sendable { case empty, formatUnavailable, bufferAllocationFailed }

    public static func write(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw WriterError.empty }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000,
            channels: 1, interleaved: true) else {
            throw WriterError.formatUnavailable
        }
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: outFormat.commonFormat, interleaved: outFormat.isInterleaved)

        // Source Float samples must be converted to Int16. Build a float buffer,
        // then convert to the Int16 output format for the write.
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false),
              let floatBuffer = AVAudioPCMBuffer(
                pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: floatFormat, to: outFormat) else {
            throw WriterError.bufferAllocationFailed
        }
        floatBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            floatBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        guard let intBuffer = AVAudioPCMBuffer(
            pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw WriterError.bufferAllocationFailed
        }
        // One-shot float32→Int16 conversion (no sample-rate change, so the
        // whole input converts in a single call — available since macOS 12,
        // well under our 14.4 floor). Guard the output frame count against a
        // silent truncation before writing: the manual pull-block form discards
        // the output status and can write a short/empty buffer without error.
        try converter.convert(to: intBuffer, from: floatBuffer)
        guard intBuffer.frameLength == AVAudioFrameCount(samples.count) else {
            throw WriterError.bufferAllocationFailed
        }
        try file.write(from: intBuffer)
        // file is released here → AVAudioFile finalizes the WAV container on disk.
    }
}
