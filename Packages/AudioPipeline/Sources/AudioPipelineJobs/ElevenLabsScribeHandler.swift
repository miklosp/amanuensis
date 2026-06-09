import Foundation

// HTTP handler for the ElevenLabs Speech-to-Text endpoint (the
// "elevenLabsScribe" shape).
//
// Wire shape:
//   POST {baseURL}/v1/speech-to-text
//   xi-api-key: <key>
//   Content-Type: multipart/form-data; boundary=Boundary-<uuid>
//   parts: model_id (= job.model), file (the audio), plus any of
//          language_code / diarize / num_speakers / timestamps_granularity /
//          tag_audio_events present in job.fields.
public enum ElevenLabsScribeHandler {
    public enum BuildError: Error, Equatable {
        case missingModel
        case invalidBaseURL
        case audioReadFailed
    }

    // Optional form fields copied straight from job.fields when present & non-empty.
    private static let optionalFields = [
        "language_code", "diarize", "num_speakers",
        "timestamps_granularity", "tag_audio_events",
    ]

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let endpoint = URL(string: trimmedBase + "/v1/speech-to-text") else {
            throw BuildError.invalidBaseURL
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        appendField("model_id", job.model)
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                appendField(key, value)
            }
        }

        // File part last.
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/flac\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
    }

    // Maps the JSON response to the string JobRunner writes. "json" → the raw
    // response, pretty-printed (original snake_case keys, sorted for stable
    // output); anything else → speaker-labelled transcript, falling back to
    // plain text when the response carries no speaker ids.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let resp = try? decoder.decode(Response.self, from: data) else {
            throw SendError.malformedResponse
        }
        return resp.labelledTranscript()
    }

    struct Response: Decodable {
        struct Word: Decodable {
            let text: String
            let speakerId: String?
        }
        let text: String
        let words: [Word]?

        // Groups consecutive words by speaker; assigns "Speaker N" in first-seen
        // order. Words with no speaker id attach to the current run. Returns the
        // plain transcript when no word carries a speaker id.
        func labelledTranscript() -> String {
            guard let words, words.contains(where: { $0.speakerId != nil }) else {
                return text
            }
            var runs: [(speaker: String, text: String)] = []
            for w in words {
                if let speaker = w.speakerId, runs.last?.speaker != speaker {
                    runs.append((speaker, w.text))
                } else if !runs.isEmpty {
                    runs[runs.count - 1].text += w.text
                }
                // Words before the first identified speaker are unattributable
                // preamble (e.g. a leading audio event) — drop them rather than
                // invent a phantom "Speaker 1".
            }
            var order: [String: Int] = [:]
            var next = 1
            let lines = runs.map { run -> String in
                let n: Int
                if let existing = order[run.speaker] {
                    n = existing
                } else {
                    n = next
                    order[run.speaker] = next
                    next += 1
                }
                return "Speaker \(n): \(run.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return lines.joined(separator: "\n")
        }
    }
}

// File-local: append a String's UTF-8 bytes to Data (Foundation has no helper).
private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
