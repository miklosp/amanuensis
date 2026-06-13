import AVFoundation
import Foundation
import Testing
@testable import RecordingCore

@Suite struct AVAudioPCMBufferDeepCopyTests {
    @Test func deepCopy_isIndependentOfSource() throws {
        let format = SyntheticAudio.stereo48kHz
        let source = SyntheticAudio.makeBuffer(format: format, frameCount: 512)
        let copy = try #require(source.deepCopy())

        #expect(copy.frameLength == source.frameLength)
        #expect(copy.format == source.format)

        // Snapshot the copy, then scribble over the source's storage the way
        // AVAudioEngine would when it reuses the tap buffer. A correct deep copy
        // must not see those mutations.
        let channels = Int(format.channelCount)
        let frames = Int(source.frameLength)
        let copySnapshot: [[Float]] = (0..<channels).map { ch in
            Array(UnsafeBufferPointer(start: copy.floatChannelData![ch], count: frames))
        }

        for ch in 0..<channels {
            let samples = source.floatChannelData![ch]
            for frame in 0..<frames { samples[frame] = -999.0 }
        }

        for ch in 0..<channels {
            let after = copy.floatChannelData![ch]
            for frame in 0..<frames {
                #expect(after[frame] == copySnapshot[ch][frame])
                #expect(after[frame] != -999.0)
            }
        }
    }

    @Test func deepCopy_zeroFrames_returnsNil() {
        let buffer = SyntheticAudio.makeBuffer(format: SyntheticAudio.mono44kHz, frameCount: 1)
        buffer.frameLength = 0
        #expect(buffer.deepCopy() == nil)
    }
}
