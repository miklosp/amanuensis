/// Pure segment boundary logic for auto-dictation. Consumes VAD events (one per
/// audio frame) and decides what the controller should do with that frame.
///
/// FluidAudio's streaming VAD already enforces the endpoint pause
/// (`minSilenceDuration`) and speech-onset threshold, so this type only adds the
/// max-segment force-cut and tracks idle/capturing. It is deliberately pure so it
/// can be exhaustively unit-tested without audio or a model.
public struct AutoDictationSegmenter: Sendable {
    public enum VoiceEvent: Sendable, Equatable { case none, speechStart, speechEnd }

    public enum Action: Sendable, Equatable {
        case ignore              // idle, no speech: drop the frame
        case beginSegment        // start a new segment; controller writes pre-roll + this frame
        case appendFrame         // capturing: write this frame to the current segment
        case finalizeSegment     // endpoint reached: close + transcribe; now idle
        case rolloverSegment     // max-cut: close current (transcribe), open a new one, write this frame
    }

    private enum State { case idle, capturing }
    private var state: State = .idle
    private var framesInSegment = 0
    private let maxSegmentFrames: Int

    public init(maxSegmentFrames: Int) {
        precondition(maxSegmentFrames > 0, "maxSegmentFrames must be positive")
        self.maxSegmentFrames = maxSegmentFrames
    }

    public mutating func step(_ event: VoiceEvent) -> Action {
        switch state {
        case .idle:
            guard event == .speechStart else { return .ignore }
            state = .capturing
            framesInSegment = 1
            return .beginSegment
        case .capturing:
            if event == .speechEnd {
                state = .idle
                framesInSegment = 0
                return .finalizeSegment
            }
            framesInSegment += 1
            if framesInSegment >= maxSegmentFrames {
                framesInSegment = 1   // this frame starts the fresh segment
                return .rolloverSegment
            }
            return .appendFrame
        }
    }
}
