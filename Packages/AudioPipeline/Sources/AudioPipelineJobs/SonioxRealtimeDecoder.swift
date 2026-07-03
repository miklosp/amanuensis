// SonioxRealtimeDecoder.swift
import Foundation

public struct SonioxToken: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) { self.text = text; self.isFinal = isFinal }
}

public struct SonioxRealtimeFrame: Sendable, Equatable {
    public let tokens: [SonioxToken]
    public let finished: Bool
    public init(tokens: [SonioxToken], finished: Bool) { self.tokens = tokens; self.finished = finished }
}

/// Pure per-frame decode. Never throws — a stray frame decodes to an empty frame
/// so it can't tear down the stream.
public enum SonioxRealtimeDecoder {
    private struct Message: Decodable {
        struct Token: Decodable {
            let text: String?
            let isFinal: Bool?
            enum CodingKeys: String, CodingKey { case text; case isFinal = "is_final" }
        }
        let tokens: [Token]?
        let finished: Bool?
    }

    public static func decode(_ json: String) -> SonioxRealtimeFrame {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            return SonioxRealtimeFrame(tokens: [], finished: false)
        }
        let tokens = (msg.tokens ?? []).map {
            SonioxToken(text: $0.text ?? "", isFinal: $0.isFinal ?? false)
        }
        return SonioxRealtimeFrame(tokens: tokens, finished: msg.finished ?? false)
    }
}

/// Folds Soniox's token frames into the `CommitController` contract: final tokens
/// accumulate into the current segment; each frame emits the current hypothesis
/// (accumulated finals + this frame's non-final tail) as a `.partial`; a
/// `finished` frame emits the segment once as `.final` and resets.
public struct SonioxTranscriptFolder: Sendable {
    private var segmentFinal = ""
    public init() {}

    public mutating func fold(_ frame: SonioxRealtimeFrame) -> [TranscriptEvent] {
        segmentFinal += frame.tokens.filter { $0.isFinal }.map(\.text).joined()
        if frame.finished {
            let done = segmentFinal.trimmingCharacters(in: .whitespaces)
            segmentFinal = ""
            return done.isEmpty ? [] : [.final(done)]
        }
        let tail = frame.tokens.filter { !$0.isFinal }.map(\.text).joined()
        let hypothesis = (segmentFinal + tail).trimmingCharacters(in: .whitespaces)
        return hypothesis.isEmpty ? [] : [.partial(hypothesis)]
    }
}
