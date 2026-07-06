import Testing
@testable import DictationCore

struct AutoDictationSegmenterTests {
    @Test func silenceWhileIdleIsIgnored() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        #expect(s.step(.none) == .ignore)
    }

    @Test func speechStartBeginsSegment() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        #expect(s.step(.speechStart) == .beginSegment)
    }

    @Test func framesWhileCapturingAppend() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        _ = s.step(.speechStart)
        #expect(s.step(.none) == .appendFrame)
        #expect(s.step(.none) == .appendFrame)
    }

    @Test func speechEndFinalizes() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 10)
        _ = s.step(.speechStart)
        _ = s.step(.none)
        #expect(s.step(.speechEnd) == .finalizeSegment)
        // Back to idle: further silence ignored.
        #expect(s.step(.none) == .ignore)
    }

    @Test func maxCutRollsOverInsteadOfAppending() {
        // maxSegmentFrames = 3: beginSegment counts as frame 1, then 2 appends,
        // the 3rd frame while capturing hits the cap and rolls over.
        var s = AutoDictationSegmenter(maxSegmentFrames: 3)
        #expect(s.step(.speechStart) == .beginSegment) // frame 1
        #expect(s.step(.none) == .appendFrame)         // frame 2
        #expect(s.step(.none) == .rolloverSegment)     // frame 3 → cap → new segment (frame 1)
        #expect(s.step(.none) == .appendFrame)         // frame 2 of new segment
    }

    @Test func speechEndTakesPriorityOverMaxCut() {
        var s = AutoDictationSegmenter(maxSegmentFrames: 2)
        _ = s.step(.speechStart)                        // frame 1
        #expect(s.step(.speechEnd) == .finalizeSegment) // end wins even though cap would hit
    }
}
