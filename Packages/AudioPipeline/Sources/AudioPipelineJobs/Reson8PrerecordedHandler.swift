import Foundation

// HTTP handler for Reson8's prerecorded speech-to-text endpoint (the
// "reson8Prerecorded" shape).
//
// Wire shape:
//   POST {baseURL}/v1/speech-to-text/prerecorded?<options>
//   Authorization: ApiKey <key>
//   Content-Type: application/octet-stream
//   body: the raw audio bytes (Reson8 takes raw audio, not multipart)
//
// Options are URL query parameters from job.fields: language / diarize /
// max_speakers, passed through when present & non-empty. Reson8 has no required
// model — a server-side default is used — so none is sent (custom_model_id is
// not exposed). No upload-size cap is documented, so audio is sent untouched
// (unlike the multipart handler's 24 MB compression path).
public enum Reson8PrerecordedHandler {
    public enum BuildError: Error, Equatable {
        case invalidBaseURL
        case audioReadFailed
    }

    // Pass-through query params copied from job.fields when present & non-empty.
    private static let optionalFields = ["language", "diarize", "max_speakers"]

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard var components = URLComponents(string: trimmedBase + "/v1/speech-to-text/prerecorded") else {
            throw BuildError.invalidBaseURL
        }

        var items: [URLQueryItem] = []
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                items.append(URLQueryItem(name: key, value: value))
            }
        }
        if !items.isEmpty { components.queryItems = items }
        guard let endpoint = components.url else { throw BuildError.invalidBaseURL }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = audioData
        return req
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse(body: Data)
    }

    // "json" → the raw response pretty-printed (keys sorted for stable output);
    // otherwise the top-level transcript, or — when diarization produced
    // speaker-labelled segments — "Speaker N: …" lines (first-seen speaker
    // order, consecutive same-speaker segments merged). Any drift in the
    // optional segments array degrades to the flat transcript rather than failing.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse(body: data)
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SendError.malformedResponse(body: data)
        }
        return resp.labelledTranscript()
    }

    // Reson8 holds the connection while transcribing pre-recorded audio, so the
    // 60s URLSession default can abort longer recordings — wait generously,
    // matching the other synchronous handlers.
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
        session: URLSession = Reson8PrerecordedHandler.defaultSession
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
        struct Segment: Decodable {
            let text: String?
            let speakerID: Int?
            enum CodingKeys: String, CodingKey {
                case text
                case speakerID = "speaker_id"
            }
        }
        let text: String
        let segments: [Segment]?

        // Groups consecutive same-speaker segments into "Speaker N: …" lines
        // (first-seen order). Falls back to the flat top-level transcript when
        // diarization is off or no segment carries a speaker_id.
        func labelledTranscript() -> String {
            guard let segments, segments.contains(where: { $0.speakerID != nil }) else {
                return text
            }
            var runs: [(speaker: Int, parts: [String])] = []
            for seg in segments {
                guard let sid = seg.speakerID else {
                    // Segment with no speaker — attach to the current run if text is non-empty.
                    if !runs.isEmpty, let t = seg.text, !t.isEmpty {
                        runs[runs.count - 1].parts.append(t)
                    }
                    continue
                }
                if runs.last?.speaker != sid {
                    var parts: [String] = []
                    if let t = seg.text, !t.isEmpty { parts = [t] }
                    runs.append((sid, parts))
                } else {
                    if let t = seg.text, !t.isEmpty { runs[runs.count - 1].parts.append(t) }
                }
            }
            // All speaker-tagged segments had empty/missing text → no real
            // content to label; fall back to the flat transcript rather than
            // emitting bare "Speaker N:" lines.
            guard runs.contains(where: { !$0.parts.isEmpty }) else { return text }
            var order: [Int: Int] = [:]
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
                return "Speaker \(n): \(run.parts.joined(separator: " "))"
            }
            return lines.joined(separator: "\n")
        }
    }
}

// Full-detail messages for the in-app log; `localizedDescription` resolves to these.
extension Reson8PrerecordedHandler.SendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .httpError(status, body):
            return "Reson8 HTTP \(status): \(describeResponseBody(body))"
        case let .malformedResponse(body):
            return "Reson8: could not decode the response: \(describeResponseBody(body))"
        }
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it.
public struct DefaultReson8PrerecordedSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await Reson8PrerecordedHandler.send(job: job, provider: provider,
                                                audioURL: audioURL, apiKey: apiKey)
    }
}
