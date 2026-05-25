import AVFoundation
import Foundation

// Converts one recorded CAF track to a 16 kHz mono 16-bit FLAC. Runs off the
// main actor; used after a recording stops. AVAudioConverter handles the
// 48 kHz->16 kHz resample and the stereo->mono down-mix in one pass.
public enum FLACExporter {
    enum ExportError: Error {
        case converterUnavailable
        case bufferAllocationFailed
    }

    public nonisolated static func export(from source: URL, to destination: URL) async throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        // The converter target and the written buffers must equal the file's
        // processingFormat exactly — AVAudioFile.write traps hard (CAVerboseAbort,
        // uncatchable) otherwise. Forcing an Int16 processing format also makes
        // the FLAC encode at 16-bit; the 2-arg initializer would pick Float32
        // and produce a 24-bit FLAC.
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: flacSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        let outputFormat = outputFile.processingFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ExportError.converterUnavailable
        }

        let outputCapacity: AVAudioFrameCount = 8_192
        var finished = false

        while !finished {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw ExportError.bufferAllocationFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: packetCount
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

            if status == .endOfStream || status == .error {
                finished = true
            }
        }
    }
}
