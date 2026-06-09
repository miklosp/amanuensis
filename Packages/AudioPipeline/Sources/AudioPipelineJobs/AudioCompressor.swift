import AVFoundation
import Foundation

// Re-encodes an audio file to a low-bitrate mono AAC .m4a, used to fit a long
// recording under a transcription provider's upload cap (Groq/OpenAI Whisper
// reject files >25 MB). 16 kHz mono matches what Whisper transcribes at, so the
// lossy step costs negligible accuracy. Mirrors FLACExporter's streaming
// AVAudioConverter pump.
//
// `nonisolated async`, but under NonisolatedNonsendingByDefault it inherits the
// caller's actor — callers that must stay off the main actor dispatch via
// Task.detached (see TranscriptionMultipartHandler.defaultCompress).
public enum AudioCompressor {
    enum CompressError: Error {
        case converterUnavailable
        case bufferAllocationFailed
    }

    // 32 kbps mono is comfortably high quality for 16 kHz speech and yields
    // ~4 KB/s, so the 25 MB cap maps to roughly 1.5–2 h of audio.
    public nonisolated static func compressToM4A(
        source: URL, to destination: URL, bitRate: Int = 32_000
    ) async throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        // 2-arg initializer → Float32 processing format, which the AAC encoder
        // wants. The written buffers must equal this processingFormat exactly or
        // AVAudioFile.write traps hard (uncatchable), so convert into it per chunk.
        let outputFile = try AVAudioFile(forWriting: destination, settings: aacSettings)
        let outputFormat = outputFile.processingFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CompressError.converterUnavailable
        }

        let outputCapacity: AVAudioFrameCount = 8_192
        var finished = false
        while !finished {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outputCapacity
            ) else { throw CompressError.bufferAllocationFailed }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: packetCount
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: inputBuffer)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
            if status == .endOfStream || status == .error { finished = true }
        }
    }
}
