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
}

// File-local: append a String's UTF-8 bytes to Data (Foundation has no helper).
private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
