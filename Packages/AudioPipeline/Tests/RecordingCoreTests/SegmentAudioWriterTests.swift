import Testing
import AVFoundation
@testable import RecordingCore

struct SegmentAudioWriterTests {
    @Test func writesReadableWavWithExpectedFrameCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = (0..<8000).map { Float(sin(Double($0) * 0.05)) } // 0.5 s @ 16 kHz
        try SegmentAudioWriter.write(samples, to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 8000)
    }

    @Test func emptySamplesThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString).wav")
        #expect(throws: (any Error).self) { try SegmentAudioWriter.write([], to: url) }
    }
}
