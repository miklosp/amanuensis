import Foundation

/// Drives one dictation capture from trigger to insertion. Pure; the
/// coordinator performs the returned `Action`s.
public struct DictationStateMachine: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case inserting
    }

    public enum Action: Equatable, Sendable {
        case none
        case beginCapture
        case endCaptureAndTranscribe
        case insert(String)
        case showError(String)
        case showEmpty
    }

    public private(set) var phase: Phase = .idle
    public init() {}

    /// Tap toggle or PTT press. Starts capture when idle, otherwise stops.
    public mutating func startOrToggle() -> Action {
        switch phase {
        case .idle:
            phase = .listening
            return .beginCapture
        case .listening:
            phase = .transcribing
            return .endCaptureAndTranscribe
        case .transcribing, .inserting:
            return .none
        }
    }

    /// PTT release. Stops capture only if still listening.
    public mutating func release() -> Action {
        switch phase {
        case .listening:
            phase = .transcribing
            return .endCaptureAndTranscribe
        default:
            return .none
        }
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
        guard phase == .transcribing || phase == .inserting else { return .none }
        phase = .idle
        return .showError(message)
    }

    public mutating func inserted() -> Action {
        guard phase == .inserting else { return .none }
        phase = .idle
        return .none
    }
}
