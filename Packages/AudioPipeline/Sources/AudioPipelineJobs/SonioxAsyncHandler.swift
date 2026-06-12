import Foundation

// HTTP handler for the Soniox async speech-to-text API (the "sonioxAsync" shape).
//
// Unlike the synchronous handlers, transcription is a multi-step job:
//   1. POST {baseURL}/v1/files                 (multipart) → file_id
//   2. POST {baseURL}/v1/transcriptions        (json: model + file_id + options) → transcription_id
//   3. GET  {baseURL}/v1/transcriptions/{id}   poll until status == "completed"
//   4. GET  {baseURL}/v1/transcriptions/{id}/transcript → { tokens: [...] }
//   5. DELETE the transcription and the file   (best-effort cleanup)
// Every request carries `Authorization: Bearer <key>`. No client-side
// compression: Soniox async handles long audio (unlike the 25 MB sync cap).
public enum SonioxAsyncHandler {
    public enum BuildError: Error, Equatable {
        case missingModel
        case invalidBaseURL
        case audioReadFailed
    }

    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
        case transcriptionFailed(message: String)
        case timedOut
    }

    // Trims one trailing slash and appends a path; the single place base-URL
    // composition happens for every step.
    private static func endpoint(_ provider: Provider, _ path: String) throws -> URL {
        let trimmed = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
        guard let url = URL(string: trimmed + path) else { throw BuildError.invalidBaseURL }
        return url
    }

    // Step 1: multipart upload of the audio file. Content-Type is fixed to
    // audio/flac — the app only ever uploads combined.flac.
    public static func buildUploadRequest(provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        let url = try endpoint(provider, "/v1/files")
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/flac\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    // Step 2: create the transcription job. Required: model + file_id. Optional
    // keys are emitted only when their job.field is present & non-empty:
    //   enable_speaker_diarization / enable_language_identification → JSON bool
    //   language_hints "en, es" → ["en","es"]   context "<text>" → {"text": …}
    public static func buildCreateRequest(job: Job, provider: Provider, fileID: String, apiKey: String) throws -> URLRequest {
        guard !job.model.isEmpty else { throw BuildError.missingModel }
        let url = try endpoint(provider, "/v1/transcriptions")

        var payload: [String: Any] = ["model": job.model, "file_id": fileID]
        if let v = job.fields["enable_speaker_diarization"], !v.isEmpty {
            payload["enable_speaker_diarization"] = (v == "true")
        }
        if let hints = job.fields["language_hints"], !hints.isEmpty {
            let arr = hints.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !arr.isEmpty { payload["language_hints"] = arr }
        }
        if let v = job.fields["enable_language_identification"], !v.isEmpty {
            payload["enable_language_identification"] = (v == "true")
        }
        if let ctx = job.fields["context"], !ctx.isEmpty {
            payload["context"] = ["text": ctx]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return req
    }

    // Step 3: poll one transcription's status.
    public static func buildPollRequest(provider: Provider, transcriptionID: String, apiKey: String) throws -> URLRequest {
        get(try endpoint(provider, "/v1/transcriptions/\(transcriptionID)"), apiKey: apiKey)
    }

    // Step 4: fetch the finished transcript (tokens).
    public static func buildTranscriptRequest(provider: Provider, transcriptionID: String, apiKey: String) throws -> URLRequest {
        get(try endpoint(provider, "/v1/transcriptions/\(transcriptionID)/transcript"), apiKey: apiKey)
    }

    // Step 5a/5b: best-effort cleanup.
    static func buildDeleteTranscriptionRequest(provider: Provider, transcriptionID: String, apiKey: String) throws -> URLRequest {
        delete(try endpoint(provider, "/v1/transcriptions/\(transcriptionID)"), apiKey: apiKey)
    }

    static func buildDeleteFileRequest(provider: Provider, fileID: String, apiKey: String) throws -> URLRequest {
        delete(try endpoint(provider, "/v1/files/\(fileID)"), apiKey: apiKey)
    }

    private static func get(_ url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func delete(_ url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    // Maps the transcript response to the string JobRunner writes. "json" → the
    // raw body pretty-printed (sorted keys, stable); anything else → speaker-
    // labelled transcript, falling back to plain concatenated text when no token
    // carries a speaker. Keys off the actual response, not the request flag.
    static func format(data: Data, outputExt: String) throws -> String {
        if outputExt == "json" {
            guard let obj = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                           options: [.prettyPrinted, .sortedKeys]) else {
                throw SendError.malformedResponse
            }
            return String(decoding: pretty, as: UTF8.self)
        }
        guard let resp = try? JSONDecoder().decode(TranscriptResponse.self, from: data) else {
            throw SendError.malformedResponse
        }
        return resp.labelledTranscript()
    }

    // Token text carries its own spacing (Soniox concatenates token.text), so the
    // transcript is rebuilt by joining without separators.
    struct TranscriptResponse: Decodable {
        struct Token: Decodable {
            let text: String
            let speaker: Int?
        }
        let tokens: [Token]

        func labelledTranscript() -> String {
            guard tokens.contains(where: { $0.speaker != nil }) else {
                return tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var runs: [(speaker: Int, text: String)] = []
            for t in tokens {
                if let s = t.speaker, runs.last?.speaker != s {
                    runs.append((s, t.text))
                } else if !runs.isEmpty {
                    runs[runs.count - 1].text += t.text
                }
                // Tokens before the first identified speaker are dropped, matching
                // the ElevenLabs handler — no phantom "Speaker 1".
            }
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
                return "Speaker \(n): \(run.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return lines.joined(separator: "\n")
        }
    }

    // Step 1/2 responses: { "id": "..." }.
    struct IDResponse: Decodable { let id: String }

    // Step 3 response: { "status": "...", "error_message": "..." }.
    struct StatusResponse: Decodable {
        let status: String
        let errorMessage: String?
    }

    // Each individual request (esp. the multipart upload of a large FLAC) must
    // not hit URLSession's 60s inactivity default — same trap the sync handlers
    // hit. The poll loop itself is bounded separately by `deadline`.
    static let requestTimeout: TimeInterval = 600

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    // Orchestrates the full async job. `pollInterval`/`deadline` are injectable so
    // tests stay fast and deterministic; the deadline is tracked as the sum of
    // slept intervals (no wall clock). The uploaded file and the transcription are
    // deleted best-effort on every exit path.
    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = SonioxAsyncHandler.defaultSession,
        pollInterval: Duration = .seconds(3),
        deadline: Duration = .seconds(600)
    ) async throws -> String {
        let fileID = try await postForID(
            try buildUploadRequest(provider: provider, audioURL: audioURL, apiKey: apiKey),
            session: session)

        var transcriptionID: String?
        do {
            let tid = try await postForID(
                try buildCreateRequest(job: job, provider: provider, fileID: fileID, apiKey: apiKey),
                session: session)
            transcriptionID = tid
            try await waitUntilComplete(provider: provider, transcriptionID: tid, apiKey: apiKey,
                                        session: session, pollInterval: pollInterval, deadline: deadline)
            let data = try await fetchData(
                try buildTranscriptRequest(provider: provider, transcriptionID: tid, apiKey: apiKey),
                session: session)
            let result = try format(data: data, outputExt: job.outputExt)
            await cleanup(provider: provider, apiKey: apiKey, fileID: fileID,
                          transcriptionID: transcriptionID, session: session)
            return result
        } catch {
            await cleanup(provider: provider, apiKey: apiKey, fileID: fileID,
                          transcriptionID: transcriptionID, session: session)
            throw error
        }
    }

    private static func postForID(_ request: URLRequest, session: URLSession) async throws -> String {
        let data = try await fetchData(request, session: session)
        guard let decoded = try? JSONDecoder().decode(IDResponse.self, from: data) else {
            throw SendError.malformedResponse
        }
        return decoded.id
    }

    private static func fetchData(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SendError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return data
    }

    private static func waitUntilComplete(
        provider: Provider, transcriptionID: String, apiKey: String,
        session: URLSession, pollInterval: Duration, deadline: Duration
    ) async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var elapsed: Duration = .zero
        while true {
            let data = try await fetchData(
                try buildPollRequest(provider: provider, transcriptionID: transcriptionID, apiKey: apiKey),
                session: session)
            guard let status = try? decoder.decode(StatusResponse.self, from: data) else {
                throw SendError.malformedResponse
            }
            switch status.status {
            case "completed":
                return
            case "error":
                throw SendError.transcriptionFailed(message: status.errorMessage ?? "")
            default:   // queued / processing
                if elapsed >= deadline { throw SendError.timedOut }
                try await Task.sleep(for: pollInterval)
                elapsed += pollInterval
            }
        }
    }

    private static func cleanup(
        provider: Provider, apiKey: String, fileID: String,
        transcriptionID: String?, session: URLSession
    ) async {
        if let tid = transcriptionID,
           let req = try? buildDeleteTranscriptionRequest(provider: provider, transcriptionID: tid, apiKey: apiKey) {
            _ = try? await session.data(for: req)
        }
        if let req = try? buildDeleteFileRequest(provider: provider, fileID: fileID, apiKey: apiKey) {
            _ = try? await session.data(for: req)
        }
    }
}

// File-local: append a String's UTF-8 bytes to Data (Foundation has no helper).
private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it
// (and tests can inject a fake).
public struct DefaultSonioxAsyncSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await SonioxAsyncHandler.send(job: job, provider: provider,
                                          audioURL: audioURL, apiKey: apiKey)
    }
}
