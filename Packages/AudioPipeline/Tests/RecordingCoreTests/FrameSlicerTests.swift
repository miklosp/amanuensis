import Testing
@testable import RecordingCore

struct FrameSlicerTests {
    @Test func emitsNothingUntilAFullFrame() {
        var slicer = FrameSlicer(frameSize: 4)
        #expect(slicer.push([1, 2, 3]).isEmpty)
    }

    @Test func emitsOneFrameWhenExactlyFull() {
        var slicer = FrameSlicer(frameSize: 4)
        let out = slicer.push([1, 2, 3, 4])
        #expect(out == [[1, 2, 3, 4]])
    }

    @Test func emitsMultipleFramesAndBuffersRemainder() {
        var slicer = FrameSlicer(frameSize: 2)
        let out = slicer.push([1, 2, 3, 4, 5])
        #expect(out == [[1, 2], [3, 4]])
        // 5 is buffered; a single more sample completes the next frame.
        #expect(slicer.push([6]) == [[5, 6]])
    }

    @Test func accumulatesAcrossPushes() {
        var slicer = FrameSlicer(frameSize: 3)
        #expect(slicer.push([1]).isEmpty)
        #expect(slicer.push([2]).isEmpty)
        #expect(slicer.push([3]) == [[1, 2, 3]])
    }
}
