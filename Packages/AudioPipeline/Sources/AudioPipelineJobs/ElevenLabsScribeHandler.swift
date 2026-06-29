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

        var form = MultipartFormBody()
        form.addField("model_id", job.model)
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                form.addField(key, value)
            }
        }
        // File part last.
        form.addFile(name: "file", filename: audioURL.lastPathComponent,
                     contentType: "audio/flac", data: audioData)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue(form.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finished()
        return req
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse(body: Data)
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
                throw SendError.malformedResponse(body: data)
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let resp = try? decoder.decode(Response.self, from: data) else {
            throw SendError.malformedResponse(body: data)
        }
        return resp.labelledTranscript()
    }

    // ElevenLabs' synchronous speech-to-text holds the connection open while it
    // transcribes, sending no bytes until done — so URLSession's default 60s
    // request (inactivity) timeout aborts real recordings with NSURLErrorTimedOut.
    // Wait generously for the transcript instead. (Very long audio is better
    // served by ElevenLabs' async webhook mode, which we don't use yet.)
    static let requestTimeout: TimeInterval = 600

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = ElevenLabsScribeHandler.defaultSession
    ) async throws -> String {
        let request = try buildRequest(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse(body: data)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try format(data: data, outputExt: job.outputExt)
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
            return formatSpeakerRuns(runs.map { run in
                (speaker: run.speaker, text: run.text.trimmingCharacters(in: .whitespacesAndNewlines))
            })
        }
    }
}

// Full-detail messages for the in-app log; `localizedDescription` resolves to these.
extension ElevenLabsScribeHandler.SendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .httpError(status, body):
            return "ElevenLabs HTTP \(status): \(describeResponseBody(body))"
        case let .malformedResponse(body):
            return "ElevenLabs: could not decode the response: \(describeResponseBody(body))"
        }
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it.
public struct DefaultElevenLabsScribeSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await ElevenLabsScribeHandler.send(job: job, provider: provider,
                                               audioURL: audioURL, apiKey: apiKey)
    }
}
