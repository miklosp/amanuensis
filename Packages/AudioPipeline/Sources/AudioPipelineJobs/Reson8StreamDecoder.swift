import Foundation

/// A decoded Reson8 Realtime server message, normalized for the commit window.
public enum Reson8StreamEvent: Sendable, Equatable {
    case partial(String)              // interim transcript (is_final == false)
    case final(String)                // final transcript (is_final == true, or interim off)
    case flushConfirmed(id: String?)  // response to a flush_request
    case ignored                      // unknown type, non-transcript, or malformed
}

/// Pure decoder for Reson8 Realtime text frames. Never throws — a stray or
/// malformed frame must not tear down the stream; it decodes to `.ignored`.
public enum Reson8StreamDecoder {
    private struct Message: Decodable {
        let type: String
        let text: String?
        let isFinal: Bool?
        let id: String?
        enum CodingKeys: String, CodingKey {
            case type, text, id
            case isFinal = "is_final"
        }
    }

    public static func decode(_ json: String) -> Reson8StreamEvent {
        guard let data = json.data(using: .utf8),
              let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            return .ignored
        }
        switch msg.type {
        case "transcript":
            guard let text = msg.text else { return .ignored }
            // With include_interim off, `is_final` is absent and every transcript
            // is already final → treat a missing flag as final.
            return (msg.isFinal ?? true) ? .final(text) : .partial(text)
        case "flush_confirmation":
            return .flushConfirmed(id: msg.id)
        default:
            return .ignored
        }
    }
}
