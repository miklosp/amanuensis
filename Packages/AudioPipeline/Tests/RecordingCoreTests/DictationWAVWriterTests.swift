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
