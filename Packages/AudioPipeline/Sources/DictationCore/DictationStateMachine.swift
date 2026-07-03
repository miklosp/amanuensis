import Foundation

/// Drives one dictation capture from trigger to insertion. Pure; the
/// coordinator performs the returned `Action`s.
public struct DictationStateMachine: Sendable {
    public enum Mode: Sendable { case batch, streaming }

    public enum Phase: Equatable, Sendable {
        case idle
        case listening       // batch capture
        case transcribing    // batch: file → text
        case inserting       // batch: pasting result
        case streaming       // live capture + live insertion
        case finalizing      // awaiting trailing finals after stop
    }

    public enum Action: Equatable, Sendable {
        case none
        case beginCapture
        case endCaptureAndTranscribe
        case insert(String)
        case showError(String)
        case showEmpty
        case beginStreamingCapture
        case endStreamingCapture
    }

    public private(set) var phase: Phase = .idle
    private let mode: Mode
    public init(mode: Mode = .batch) { self.mode = mode }

    /// Tap toggle or PTT press. Starts capture when idle, otherwise stops.
    public mutating func startOrToggle() -> Action {
        switch phase {
        case .idle:
            switch mode {
            case .batch:     phase = .listening; return .beginCapture
            case .streaming: phase = .streaming; return .beginStreamingCapture
            }
        case .listening:
            phase = .transcribing; return .endCaptureAndTranscribe
        case .streaming:
            phase = .finalizing; return .endStreamingCapture
        case .transcribing, .inserting, .finalizing:
            return .none
        }
    }

    /// PTT release. Stops capture only if still listening.
    public mutating func release() -> Action {
        switch phase {
        case .listening:
            phase = .transcribing; return .endCaptureAndTranscribe
        case .streaming:
            phase = .finalizing; return .endStreamingCapture
        default:
            return .none
        }
    }

    /// Streaming: trailing finals drained, capture torn down → back to idle.
    public mutating func finalized() -> Action {
        guard phase == .finalizing else { return .none }
        phase = .idle
        return .none
    }

    public mutating func transcriptReady(_ text: String) -> Action {
        guard phase == .transcribing else { return .none }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            phase = .idle
            return .showEmpty
        }
        phase = .inserting
        return .insert(text)
    }

    public mutating func failed(_ message: String) -> Action {
        // Abort any active capture/transcription back to idle (no-op only when
        // already idle). Lets the coordinator recover from a failed beginCapture.
        guard phase != .idle else { return .none }
        phase = .idle
        return .showError(message)
    }

    public mutating func inserted() -> Action {
        guard phase == .inserting else { return .none }
        phase = .idle
        return .none
    }

    /// Force back to idle, abandoning any in-flight capture. Used when the
    /// coordinator tears a capture down out-of-band (provider removed, dictation
    /// disabled); the coordinator performs the actual recorder/file teardown.
    public mutating func reset() {
        phase = .idle
    }
}
