import AVFoundation
import Foundation

// Mixes mic + system tracks into a single 16 kHz mono FLAC by mono-summing
// in Float32 PCM, then encoding the mixed buffer to FLAC. Mic is required;
// system is optional (mic-only recordings happen when the system tap is
// denied or unavailable). Used after a recording stops.
//
// Note: this is `nonisolated async`, but under `NonisolatedNonsendingByDefault`
// (enabled for this target) it inherits the caller's actor. Callers that need
// it off the main actor must dispatch via `Task.detached` or an equivalent
// background executor.
public enum CombinedFLACExporter {
    enum ExportError: Error {
        case mixFormatUnavailable
        case bufferAllocationFailed
        case converterUnavailable
    }

    public nonisolated static func combine(
        mic: URL,
        system: URL?,
        to destination: URL
    ) async throws {
        // Target mix format: 16 kHz mono Float32, used as the intermediate
        // and as the engine output. Final FLAC is 16 kHz mono Int16.
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw ExportError.mixFormatUnavailable }

        let micBuffer = try Self.readAndConvert(url: mic, to: mixFormat)
        // If `system` is nil, skip. If it's set but reading/converting fails
        // (file missing, unreadable, etc.) treat as mic-only rather than
        // failing the whole export — a system tap denial shouldn't lose the
        // mic recording.
        let systemBuffer: AVAudioPCMBuffer? = {
            guard let system else { return nil }
            return try? Self.readAndConvert(url: system, to: mixFormat)
        }()

        let mixed = Self.sumMono(micBuffer, systemBuffer, format: mixFormat)
        try Self.writeFLAC(buffer: mixed, to: destination)
    }

    // Read entire file → resample/downmix to mixFormat → return one big buffer.
    private nonisolated static func readAndConvert(
        url: URL, to mixFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: mixFormat) else {
            throw ExportError.converterUnavailable
        }

        // Estimate output frame capacity. AVAudioConverter may produce a few
        // extra frames at end-of-stream, so add a small headroom.
        let inputFrames = inputFile.length
        let ratio = mixFormat.sampleRate / inputFormat.sampleRate
        let estimatedOutputFrames = AVAudioFrameCount(Double(inputFrames) * ratio) + 1024

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: mixFormat,
            frameCapacity: max(estimatedOutputFrames, 1)
        ) else { throw ExportError.bufferAllocationFailed }

        // Pump in chunks of input frames, append converter output into outputBuffer.
        let chunkCapacity: AVAudioFrameCount = 8_192
        var done = false
        while !done {
            guard let chunk = AVAudioPCMBuffer(
                pcmFormat: mixFormat,
                frameCapacity: chunkCapacity
            ) else { throw ExportError.bufferAllocationFailed }

            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { packetCount, statusOut in
                guard let inputChunk = AVAudioPCMBuffer(
                    pcmFormat: inputFormat,
                    frameCapacity: packetCount
                ) else {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: inputChunk)
                } catch {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                if inputChunk.frameLength == 0 {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                statusOut.pointee = .haveData
                return inputChunk
            }
            if let conversionError { throw conversionError }
            if chunk.frameLength > 0 {
                try Self.appendBuffer(chunk, to: outputBuffer)
            }
            if status == .endOfStream || status == .error { done = true }
        }
        return outputBuffer
    }

    private nonisolated static func appendBuffer(
        _ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer
    ) throws {
        guard src.format.commonFormat == .pcmFormatFloat32,
              src.format.channelCount == 1,
              dst.format.commonFormat == .pcmFormatFloat32,
              dst.format.channelCount == 1 else {
            throw ExportError.bufferAllocationFailed
        }
        let writeStart = Int(dst.frameLength)
        let count = Int(src.frameLength)
        guard writeStart + count <= Int(dst.frameCapacity),
              let srcPtr = src.floatChannelData?[0],
              let dstPtr = dst.floatChannelData?[0] else {
            throw ExportError.bufferAllocationFailed
        }
        for i in 0..<count { dstPtr[writeStart + i] = srcPtr[i] }
        dst.frameLength = AVAudioFrameCount(writeStart + count)
    }

    // Pointwise sum a + b (b may be nil). Output length = max(a.frameLength, b.frameLength).
    // Clips final samples to [-1.0, 1.0] (post-clip would otherwise wrap on Int16 encode).
    private nonisolated static func sumMono(
        _ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer?, format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let aFrames = Int(a.frameLength)
        let bFrames = Int(b?.frameLength ?? 0)
        let outFrames = AVAudioFrameCount(max(aFrames, bFrames))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(outFrames, 1)),
              let outPtr = out.floatChannelData?[0],
              let aPtr = a.floatChannelData?[0] else {
            // Should never happen with the formats we control; fall back to a.
            return a
        }
        out.frameLength = outFrames
        let bPtr = b?.floatChannelData?[0]
        for i in 0..<Int(outFrames) {
            let aVal: Float = i < aFrames ? aPtr[i] : 0
            let bVal: Float = (i < bFrames) ? (bPtr?[i] ?? 0) : 0
            let sum = aVal + bVal
            outPtr[i] = max(-1.0, min(1.0, sum))
        }
        return out
    }

    private nonisolated static func writeFLAC(
        buffer: AVAudioPCMBuffer, to destination: URL
    ) throws {
        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        // The converter target and the written buffers must equal the file's
        // processingFormat exactly — AVAudioFile.write traps hard
        // (CAVerboseAbort, uncatchable) otherwise. Forcing an Int16 processing
        // format also makes the FLAC encode at 16-bit; the 2-arg initializer
        // would pick Float32 and produce a 24-bit FLAC.
        let outputFile = try AVAudioFile(
            forWriting: destination,
            settings: flacSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        // outputFile.processingFormat is 16 kHz mono Int16. We have Float32;
        // convert per chunk via AVAudioConverter (it does the Float32→Int16
        // scaling internally).
        guard let converter = AVAudioConverter(
            from: buffer.format, to: outputFile.processingFormat
        ) else { throw ExportError.converterUnavailable }

        var remaining = Int(buffer.frameLength)
        var readCursor = 0
        let chunkSize: AVAudioFrameCount = 8_192
        while remaining > 0 {
            let inputCount = AVAudioFrameCount(min(remaining, Int(chunkSize)))
            // Output capacity equals input count (1:1 ratio: same sample rate, same channels).
            guard let outChunk = AVAudioPCMBuffer(
                pcmFormat: outputFile.processingFormat, frameCapacity: inputCount
            ) else { throw ExportError.bufferAllocationFailed }

            var providedOnce = false
            var conversionError: NSError?
            _ = converter.convert(to: outChunk, error: &conversionError) { _, statusOut in
                guard !providedOnce else {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                providedOnce = true
                guard let inChunk = AVAudioPCMBuffer(
                    pcmFormat: buffer.format, frameCapacity: inputCount
                ) else {
                    statusOut.pointee = .endOfStream
                    return nil
                }
                inChunk.frameLength = inputCount
                if let dst = inChunk.floatChannelData?[0],
                   let src = buffer.floatChannelData?[0] {
                    for i in 0..<Int(inputCount) {
                        dst[i] = src[readCursor + i]
                    }
                }
                statusOut.pointee = .haveData
                return inChunk
            }
            if let conversionError { throw conversionError }
            if outChunk.frameLength > 0 {
                try outputFile.write(from: outChunk)
            }
            readCursor += Int(inputCount)
            remaining -= Int(inputCount)
        }
    }
}
