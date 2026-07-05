// OpenAIRealtimeDecoder.swift
import Foundation

/// A decoded OpenAI Realtime transcription server event, normalized for folding.
/// Unlike the raw-binary providers, OpenAI streams *incremental* text deltas plus
/// one authoritative `completed` transcript per segment.
public enum OpenAIRealtimeEvent: Sendable, Equatable {
    case delta(String)      // incremental partial text (appends to the hypothesis)
    case completed(String)  // authoritative final transcript for the segment
    case ignored            // session/lifecycle/error events, or malformed
}

/// Pure per-event decode. Never throws — an unrecognized or malformed event decodes
/// to `.ignored` so it can't tear down the stream.
public enum OpenAIRealtimeDecoder {
    private struct Message: Decodable {
        let type: String?
        let delta: String?
        let transcript: String?
    }

    public static func decode(_ json: String) -> OpenAIRealtimeEvent {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            return .ignored
        }
        switch msg.type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = msg.delta else { return .ignored }
            return .delta(delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = msg.transcript else { return .ignored }
            return .completed(transcript)
        default:
            return .ignored
        }
    }
}

/// Folds OpenAI's event stream into the `CommitController` contract: `delta` text
/// accumulates into the current hypothesis, emitted as `.partial`; a `completed`
/// event emits its authoritative transcript once as `.final` and resets. Mirrors
/// the output contract of `SonioxTranscriptFolder`/`DeepgramTranscriptFolder`.
public struct OpenAITranscriptFolder: Sendable {
    private var delta = ""
    public init() {}

    public mutating func fold(_ event: OpenAIRealtimeEvent) -> [TranscriptEvent] {
        switch event {
        case .delta(let text):
            delta += text
            let hypothesis = delta.trimmingCharacters(in: .whitespaces)
            return hypothesis.isEmpty ? [] : [.partial(hypothesis)]
        case .completed(let transcript):
            delta = ""
            let done = transcript.trimmingCharacters(in: .whitespaces)
            return done.isEmpty ? [] : [.final(done)]
        case .ignored:
            return []
        }
    }
}
