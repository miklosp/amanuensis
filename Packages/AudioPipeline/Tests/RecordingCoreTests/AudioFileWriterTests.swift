import AVFoundation
import Foundation
import Testing
@testable import RecordingCore

@Suite struct AudioFileWriterTests {
    @Test func enqueue_thenClose_writesAllFramesAndOutputReadable() throws {
        try withTempDirectory { tempURL in
            let url = tempURL.appending(path: "writer.caf", directoryHint: .notDirectory)
            let format = SyntheticAudio.stereo48kHz
            let writer = try AudioFileWriter(url: url, format: format, label: "test")

            let frameCounts: [AVAudioFrameCount] = [4096, 4096, 1024]
            for count in frameCounts {
                writer.enqueue(SyntheticAudio.makeBuffer(format: format, frameCount: count))
            }

            let total = writer.close()
            let expected = Int64(frameCounts.reduce(0, +))
            #expect(total == expected)

            let readback = try AVAudioFile(forReading: url)
            #expect(readback.length == expected)
        }
    }

    @Test func enqueueAfterClose_isNoOp() throws {
        try withTempDirectory { tempURL in
            let url = tempURL.appending(path: "writer.caf", directoryHint: .notDirectory)
            let format = SyntheticAudio.mono44kHz
            let writer = try AudioFileWriter(url: url, format: format, label: "test")

            writer.enqueue(SyntheticAudio.makeBuffer(format: format, frameCount: 2048))
            let firstClose = writer.close()
            #expect(firstClose == 2048)

            // Post-close enqueue is silently dropped.
            writer.enqueue(SyntheticAudio.makeBuffer(format: format, frameCount: 4096))

            // Re-opening the file: length must still match what was written
            // BEFORE close; the second enqueue must not have appended anything.
            let readback = try AVAudioFile(forReading: url)
            #expect(readback.length == 2048)
        }
    }

    @Test func doubleClose_isSafeAndReturnsStableCount() throws {
        try withTempDirectory { tempURL in
            let url = tempURL.appending(path: "writer.caf", directoryHint: .notDirectory)
            let format = SyntheticAudio.stereo48kHz
            let writer = try AudioFileWriter(url: url, format: format, label: "test")

            writer.enqueue(SyntheticAudio.makeBuffer(format: format, frameCount: 1024))

            let first = writer.close()
            let second = writer.close()
            #expect(first == second)
            #expect(first == 1024)
        }
    }
}
