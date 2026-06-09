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

    public static func buildRequest(job: Job, provider: Provider, audioURL: URL, apiKey: String) throws -> URLRequest {
        guard let prompt = job.fields["prompt"], !prompt.isEmpty else {
            throw BuildError.missingPrompt
        }

        let trimmedBase = provider.baseURL.hasSuffix("/") ? String(provider.baseURL.dropLast()) : provider.baseURL
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

        let contentBlocks: [[String: Any]] = [
            ["type": "input_audio",
             "input_audio": [
                "data": audioData.base64EncodedString(),
                "format": format,
             ]],
            ["type": "text", "text": prompt],
        ]

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

extension ChatCompletionsAudioHandler {
    public enum SendError: Error {
        case httpError(status: Int, body: Data)
        case malformedResponse
    }

    public static func send(
        job: Job,
        provider: Provider,
        audioURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> String {
        let request = try buildRequest(job: job, provider: provider, audioURL: audioURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SendError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.httpError(status: http.statusCode, body: data)
        }
        return try parseContent(data: data)
    }

    static func parseContent(data: Data) throws -> String {
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            guard let first = env.choices.first else { throw SendError.malformedResponse }
            return first.message.content
        } catch is SendError {
            throw SendError.malformedResponse
        } catch {
            throw SendError.malformedResponse
        }
    }
}

// Adapts the static `send` to AudioJobSending so JobRunner can dispatch to it
// (and tests can inject a fake).
public struct DefaultChatCompletionsAudioSender: AudioJobSending {
    public init() {}
    public func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        try await ChatCompletionsAudioHandler.send(job: job, provider: provider,
                                                   audioURL: audioURL, apiKey: apiKey)
    }
}
