import Foundation

// HTTP handler for Deepgram's pre-recorded transcription endpoint (the
// "deepgramListen" shape).
//
// Wire shape:
//   POST {baseURL}/v1/listen?model=<job.model>&<options>
//   Authorization: Token <key>
//   Content-Type: audio/flac
//   body: the raw audio bytes (Deepgram takes raw audio, not multipart)
//
// Options are URL query parameters built from job.fields: language / diarize /
// smart_format passed through when present & non-empty, and keyterm split on
// commas into one parameter per term (Nova-3 keyterm biasing).
public enum DeepgramListenHandler {
    public enum BuildError: Error, Equatable {
        case missingModel
        case invalidBaseURL
        case audioReadFailed
    }

    // Pass-through query params copied from job.fields when present & non-empty.
    private static let optionalFields = ["language", "diarize", "smart_format"]

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard var components = URLComponents(string: trimmedBase + "/v1/listen") else {
            throw BuildError.invalidBaseURL
        }

        var items = [URLQueryItem(name: "model", value: job.model)]
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                items.append(URLQueryItem(name: key, value: value))
            }
        }
        if let keyterm = job.fields["keyterm"], !keyterm.isEmpty {
            for term in keyterm.split(separator: ",") {
                let trimmed = term.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { items.append(URLQueryItem(name: "keyterm", value: trimmed)) }
            }
        }
        components.queryItems = items
        guard let endpoint = components.url else { throw BuildError.invalidBaseURL }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/flac", forHTTPHeaderField: "Content-Type")
        req.httpBody = audioData
        return req
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse(body: Data)
    }

    // "json" → the raw response pretty-printed (keys sorted for stable output);
    // anything else → the plain transcript from the first channel's top
    // alternative. Speaker-labelled output (when diarize is on) lives in the
    // JSON response — text mode returns the flat transcript.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse(body: data)
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              let transcript = resp.results.channels.first?.alternatives.first?.transcript else {
            throw SendError.malformedResponse(body: data)
        }
        return transcript
    }

    // Deepgram holds the connection while transcribing pre-recorded audio, so
    // the 60s URLSession default can abort longer recordings — wait generously,
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
        session: URLSession = DeepgramListenHandler.defaultSession
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
        struct Results: Decodable {
            struct Channel: Decodable {
                struct Alternative: Decodable { let transcript: String }
                let alternatives: [Alternative]
            }
            let channels: [Channel]
        }
        let results: Results
    }
}

// Full-detail messages for the in-app log; `localizedDescription` resolves to these.
extension DeepgramListenHandler.SendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .httpError(status, body):
            return "Deepgram HTTP \(status): \(describeResponseBody(body))"
        case let .malformedResponse(body):
            return "Deepgram: could not decode the response: \(describeResponseBody(body))"
        }
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it.
public struct DefaultDeepgramListenSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await DeepgramListenHandler.send(job: job, provider: provider,
                                             audioURL: audioURL, apiKey: apiKey)
    }
}
