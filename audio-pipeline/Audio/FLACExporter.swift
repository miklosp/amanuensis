import AVFoundation
import Foundation

// Converts one recorded CAF track to a 16 kHz mono 16-bit FLAC. Runs off the
// main actor; used after a recording stops. AVAudioConverter handles the
// 48 kHz->16 kHz resample and the stereo->mono down-mix in one pass.
enum FLACExporter {
    enum ExportError: Error {
        case targetFormatUnavailable
        case converterUnavailable
        case bufferAllocationFailed
    }

    nonisolated static func export(from source: URL, to destination: URL) async throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw ExportError.targetFormatUnavailable
        }

        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        let outputFile = try AVAudioFile(forWriting: destination, settings: flacSettings)

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
