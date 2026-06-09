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
}

// File-local: append a String's UTF-8 bytes to Data (Foundation has no helper).
private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
