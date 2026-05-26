import Foundation

// HTTP handler for the OpenAI-compatible chat-completions endpoint with an
// input_audio content block (the "openai-file-b64" shape).
//
// Wire shape:
//   POST {baseURL}/v1/chat/completions
//   Authorization: Bearer <key>
//   Content-Type: application/json
//   {
//     "model": "...",
//     "messages": [{"role": "user", "content": [
//        {"type": "input_audio", "input_audio": {"data": "<base64>", "format": "flac"}},
//        {"type": "text", "text": "<prompt>"}
//     ]}],
//     "temperature": 0.3  // optional
//   }
public enum ChatCompletionsAudioHandler {
    public enum BuildError: Error, Equatable {
        case missingPrompt
        case invalidBaseURL
        case audioReadFailed
    }

    public static func buildRequest(job: Job, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard let prompt = job.fields["prompt"], !prompt.isEmpty else {
            throw BuildError.missingPrompt
        }

        let trimmedBase = job.baseURL.hasSuffix("/") ? String(job.baseURL.dropLast()) : job.baseURL
        guard let endpoint = URL(string: trimmedBase + "/v1/chat/completions") else {
            throw BuildError.invalidBaseURL
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw BuildError.audioReadFailed
        }

        let format = resolveFormat(declared: job.fields["audio_format"], audioURL: audioURL)

        var contentBlocks: [[String: Any]] = [
            ["type": "input_audio",
             "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": format,
             ]],
            ["type": "text", "text": prompt],
        ]
        _ = contentBlocks  // silence "may be unused" if ever reordered

        var body: [String: Any] = [
            "model": job.model,
            "messages": [
                ["role": "user", "content": contentBlocks],
            ],
        ]
        if let tempStr = job.fields["temperature"], let temp = Double(tempStr) {
            body["temperature"] = temp
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    private static func resolveFormat(declared: String?, audioURL: URL) -> String {
        if let declared, declared != "auto", !declared.isEmpty {
            return declared
        }
        let ext = audioURL.pathExtension.lowercased()
        return ext.isEmpty ? "flac" : ext
    }
}
