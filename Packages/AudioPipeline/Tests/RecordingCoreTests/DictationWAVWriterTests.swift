import AVFoundation
import Foundation
import Testing
@testable import RecordingCore

@Suite struct DictationWAVWriterTests {
    // Regression: the writer must accept hardware-format (48 kHz stereo float)
    // input, convert it, and write a 16 kHz mono WAV. Previously it opened the
    // file with the 2-arg AVAudioFile initializer — whose processingFormat is
    // the standard float32/deinterleaved — then wrote an Int16/interleaved
    // buffer, so AVAudioFile.write aborted the process (ExtAudioFile assertion)
    // on the first buffer.
    // Collects onChunk output across the writer's private queue; read only after
    // `close()`, whose await is a happens-before barrier over the queued writes.
    private final class ChunkCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    @Test func onChunk_emitsInt16Bytes_oneSamplePerWrittenFrame() async throws {
        try await withTempDirectory { tempURL in
            let url = tempURL.appending(path: "dictation.wav", directoryHint: .notDirectory)
            let inputFormat = SyntheticAudio.stereo48kHz
            let collector = ChunkCollector()
            let writer = try DictationWAVWriter(
                url: url, inputFormat: inputFormat, onLevel: nil,
                onChunk: { collector.append($0) })

            for count: AVAudioFrameCount in [4800, 4800, 4800] {
                writer.enqueue(SyntheticAudio.makeBuffer(format: inputFormat, frameCount: count))
            }
            let frames = await writer.close()

            let bytes = collector.bytes
            #expect(!bytes.isEmpty)
            #expect(bytes.count % MemoryLayout<Int16>.size == 0)   // whole Int16 samples
            #expect(Int64(bytes.count / MemoryLayout<Int16>.size) == frames)
        }
    }

    @Test func enqueue_convertsHardwareInputTo16kMonoWAV() async throws {
        try await withTempDirectory { tempURL in
            let url = tempURL.appending(path: "dictation.wav", directoryHint: .notDirectory)
            let inputFormat = SyntheticAudio.stereo48kHz
            let writer = try DictationWAVWriter(
                url: url, inputFormat: inputFormat, onLevel: nil)

            for count: AVAudioFrameCount in [4800, 4800, 4800] {
                writer.enqueue(SyntheticAudio.makeBuffer(format: inputFormat, frameCount: count))
            }
            let frames = await writer.close()

            #expect(frames > 0)
            let readback = try AVAudioFile(forReading: url)
            #expect(readback.fileFormat.sampleRate == 16_000)
            #expect(readback.fileFormat.channelCount == 1)
            #expect(readback.length == frames)
        }
    }
}
