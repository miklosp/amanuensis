// DeepgramRealtimeDecoder.swift
import Foundation

/// One decoded Deepgram `Results` frame, normalized for folding. Deepgram emits
/// disjoint `is_final` chunks that accumulate into an utterance; `speech_final`
/// marks the endpoint that closes it.
public struct DeepgramFrame: Sendable, Equatable {
    public let transcript: String
    public let isFinal: Bool
    public let speechFinal: Bool
    public init(transcript: String, isFinal: Bool, speechFinal: Bool) {
        self.transcript = transcript
        self.isFinal = isFinal
        self.speechFinal = speechFinal
    }
}

/// Pure per-frame decode. Returns `nil` for non-`Results` messages (`Metadata`,
/// `UtteranceEnd`, `SpeechStarted`) and malformed frames, so a stray frame can't
/// tear down the stream.
public enum DeepgramRealtimeDecoder {
    private struct Message: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable { let transcript: String? }
            let alternatives: [Alternative]?
        }
        let type: String?
        let channel: Channel?
        let isFinal: Bool?
        let speechFinal: Bool?
        enum CodingKeys: String, CodingKey {
            case type, channel
            case isFinal = "is_final"
            case speechFinal = "speech_final"
        }
    }

    public static func decode(_ json: String) -> DeepgramFrame? {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONDecoder().decode(Message.self, from: data),
              msg.type == "Results" else {
            return nil
        }
        let transcript = msg.channel?.alternatives?.first?.transcript ?? ""
        return DeepgramFrame(
            transcript: transcript,
            isFinal: msg.isFinal ?? false,
            speechFinal: msg.speechFinal ?? false)
    }
}

/// Folds Deepgram's frames into the `CommitController` contract: `is_final` chunks
/// accumulate (space-joined) into the current utterance; each frame emits the
/// current hypothesis (accumulated finals + this interim's tail) as a `.partial`;
/// a `speech_final` frame emits the utterance once as `.final` and resets. Mirrors
/// `SonioxTranscriptFolder`'s output contract.
public struct DeepgramTranscriptFolder: Sendable {
    private var segmentFinal = ""
    public init() {}

    public mutating func fold(_ frame: DeepgramFrame) -> [TranscriptEvent] {
        let piece = frame.transcript.trimmingCharacters(in: .whitespaces)
        if frame.isFinal {
            if !piece.isEmpty { segmentFinal = joined(segmentFinal, piece) }
            if frame.speechFinal {
                let done = segmentFinal.trimmingCharacters(in: .whitespaces)
                segmentFinal = ""
                return done.isEmpty ? [] : [.final(done)]
            }
            return segmentFinal.isEmpty ? [] : [.partial(segmentFinal)]
        }
        let hypothesis = joined(segmentFinal, piece).trimmingCharacters(in: .whitespaces)
        return hypothesis.isEmpty ? [] : [.partial(hypothesis)]
    }

    private func joined(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}
