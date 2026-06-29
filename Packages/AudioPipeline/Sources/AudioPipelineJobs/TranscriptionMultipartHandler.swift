import Foundation

// HTTP handler for the OpenAI-compatible audio transcription endpoint (the
// "transcriptionMultipart" shape) — Whisper / gpt-4o-transcribe, Groq, Mistral
// Voxtral, and any OpenAI-compatible gateway (e.g. Bifrost) that routes to one.
//
// Wire shape:
//   POST {baseURL}/v1/audio/transcriptions
//   Authorization: Bearer <key>
//   Content-Type: multipart/form-data; boundary=Boundary-<uuid>
//   parts: model (= job.model), file (the audio), plus any of
//          language / prompt / temperature / response_format present in
//          job.fields.
public enum TranscriptionMultipartHandler {
    public enum BuildError: Error, Equatable {
        case missingModel
        case invalidBaseURL
        case audioReadFailed
    }

    // Optional form fields copied straight from job.fields when present & non-empty.
    private static let optionalFields = ["language", "prompt", "temperature", "response_format"]

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String,
                                    path: String = "/v1/audio/transcriptions") throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let endpoint = URL(string: trimmedBase + path) else {
            throw BuildError.invalidBaseURL
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        var form = MultipartFormBody()
        form.addField("model", job.model)
        for key in optionalFields {
            if let value = job.fields[key], !value.isEmpty {
                form.addField(key, value)
            }
        }
        // File part last.
        form.addFile(name: "file", filename: audioURL.lastPathComponent,
                     contentType: mimeType(for: audioURL), data: audioData)

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(form.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        req.httpBody = form.finished()
        return req
    }

    // Maps a file extension to the multipart file part's Content-Type. Transcription
    // providers also sniff the bytes, but a correct hint avoids ambiguity — and the
    // upload may be a re-encoded .m4a (see prepareUpload), not always the .flac.
    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4":          return "audio/mp4"
        case "flac":                return "audio/flac"
        case "wav":                 return "audio/wav"
        case "mp3", "mpga", "mpeg": return "audio/mpeg"
        case "ogg", "opus":         return "audio/ogg"
        case "webm":                return "audio/webm"
        default:                    return "application/octet-stream"
        }
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse(body: Data)
    }

    // Groq / OpenAI Whisper reject uploads over 25 MB with HTTP 413. Leave a
    // little headroom for multipart framing and compress anything larger before
    // sending. See project_groq_whisper_25mb_limit.
    static let maxUploadBytes = 24 * 1024 * 1024

    typealias Compress = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    // Default: lossy AAC re-encode dispatched off the caller's actor, so a long
    // recording's encode doesn't run on the main thread (NonisolatedNonsendingByDefault
    // would otherwise keep it there).
    static let defaultCompress: Compress = { source, destination in
        try await Task.detached(priority: .utility) {
            try await AudioCompressor.compressToM4A(source: source, to: destination)
        }.value
    }

    // Returns the file to upload. Within the cap → the original, untouched. Over
    // the cap → a temporary .m4a (isTemporary = true; the caller deletes it).
    static func prepareUpload(
        audioURL: URL,
        maxBytes: Int = maxUploadBytes,
        compress: Compress = defaultCompress
    ) async throws -> (url: URL, isTemporary: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > maxBytes else { return (audioURL, false) }
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcribe-\(UUID().uuidString).m4a")
        try await compress(audioURL, dest)
        return (dest, true)
    }

    // Format-aware: the default `json` shape ({"text": "..."}) is reduced to the
    // transcript string; every richer/raw format the user explicitly asked for
    // (verbose_json, srt, vtt, text) is written verbatim so segments/subtitles
    // survive.
    static func parseResponse(data: Data, responseFormat: String?) throws -> String {
        let fmt = (responseFormat ?? "").lowercased()
        if fmt.isEmpty || fmt == "json" {
            struct Envelope: Decodable { let text: String }
            guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
                throw SendError.malformedResponse(body: data)
            }
            return env.text
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw SendError.malformedResponse(body: data)
        }
        return body
    }

    // Synchronous transcription holds the connection open while the model works,
    // sending no bytes until done — so URLSession's default 60s request
    // (inactivity) timeout aborts real recordings with NSURLErrorTimedOut. Wait
    // generously instead (same trap the ChatCompletions/ElevenLabs handlers hit).
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
        session: URLSession = TranscriptionMultipartHandler.defaultSession,
        path: String = "/v1/audio/transcriptions"
    ) async throws -> String {
        try await send(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey,
                       session: session, maxBytes: maxUploadBytes, compress: defaultCompress, path: path)
    }

    // Internal seam: lets tests drive the size threshold + compressor without
    // real encoding. The public overload above pins the production defaults.
    static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession,
        maxBytes: Int,
        compress: Compress,
        path: String = "/v1/audio/transcriptions"
    ) async throws -> String {
        let prepared = try await prepareUpload(audioURL: audioURL, maxBytes: maxBytes, compress: compress)
        defer { if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.url) } }
        let request = try buildRequest(job: job, provider: provider, audioURL: prepared.url, apiKey: apiKey, path: path)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse(body: data)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try parseResponse(data: data, responseFormat: job.fields["response_format"])
    }
}

// Full-detail messages for the in-app log; `localizedDescription` resolves to these.
extension TranscriptionMultipartHandler.SendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .httpError(status, body):
            return "Transcription HTTP \(status): \(describeResponseBody(body))"
        case let .malformedResponse(body):
            return "Transcription: could not decode the response: \(describeResponseBody(body))"
        }
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it.
public struct DefaultTranscriptionMultipartSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await TranscriptionMultipartHandler.send(job: job, provider: provider,
                                                     audioURL: audioURL, apiKey: apiKey)
    }
}
