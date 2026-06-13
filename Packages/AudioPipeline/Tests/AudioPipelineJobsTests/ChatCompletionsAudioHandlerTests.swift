import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "http://localhost:4444/openai") -> Provider {
    Provider(name: "p", presetID: "openai-compat-chat",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "bifrost"))
}

private func makeJob(prompt: String, model: String = "gemini-flash",
                     audioFormat: String? = nil,
                     temperature: String? = nil) -> Job {
    var fields: [String: String] = ["prompt": prompt]
    if let audioFormat { fields["audio_format"] = audioFormat }
    if let temperature { fields["temperature"] = temperature }
    return Job(name: "t", providerID: UUID(), model: model,
               fields: fields, outputExt: "txt")
}

private func writeAudio(_ bytes: [UInt8], ext: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("audio-\(UUID().uuidString).\(ext)")
    try Data(bytes).write(to: url)
    return url
}

@Suite struct ChatCompletionsAudioRequest {
    @Test func buildsPOST_toChatCompletionsPath() throws {
        let job = makeJob(prompt: "Hello")
        let provider = makeProvider()
        let audio = try writeAudio([0x01, 0x02], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://localhost:4444/openai/v1/chat/completions")
    }

    @Test func authorizationHeader_isBearerToken() throws {
        let job = makeJob(prompt: "Hello")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "sk-x")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func body_encodesModelMessagesAndBase64Audio() throws {
        let job = makeJob(prompt: "Transcribe.")
        let provider = makeProvider()
        let audio = try writeAudio([0xAA, 0xBB, 0xCC], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "gemini-flash")
        let messages = try #require(json?["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let inputAudio = try #require(content.first { $0["type"] as? String == "input_audio" })
        let audioObj = try #require(inputAudio["input_audio"] as? [String: Any])
        #expect(audioObj["data"] as? String == Data([0xAA, 0xBB, 0xCC]).base64EncodedString())
        #expect(audioObj["format"] as? String == "flac")
        let text = try #require(content.first { $0["type"] as? String == "text" })
        #expect(text["text"] as? String == "Transcribe.")
    }

    @Test func audioFormat_auto_derivesFromExtension() throws {
        let job = makeJob(prompt: "p", audioFormat: "auto")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "wav")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let messages = try #require(json?["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let inputAudio = try #require(content.first { $0["type"] as? String == "input_audio" })
        let audioObj = try #require(inputAudio["input_audio"] as? [String: Any])
        #expect(audioObj["format"] as? String == "wav")
    }

    @Test func temperature_isIncludedWhenSet() throws {
        let job = makeJob(prompt: "p", temperature: "0.3")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["temperature"] as? Double == 0.3)
    }

    @Test func temperature_isOmittedWhenAbsent() throws {
        let job = makeJob(prompt: "p")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["temperature"] == nil)
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let job = makeJob(prompt: "p")
        let provider = makeProvider(baseURL: "http://example.com/")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                               audioURL: audio, apiKey: "k")
        #expect(req.url?.absoluteString == "http://example.com/v1/chat/completions")
    }

    @Test func buildRequest_throws_missingPrompt_whenPromptEmpty() throws {
        var job = makeJob(prompt: "Hello")
        job.fields["prompt"] = ""
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        do {
            _ = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                             audioURL: audio, apiKey: "k")
            Issue.record("expected missingPrompt")
        } catch ChatCompletionsAudioHandler.BuildError.missingPrompt {
            // expected
        }
    }

    @Test func buildRequest_throws_audioReadFailed_whenFileMissing() throws {
        let job = makeJob(prompt: "p")
        let provider = makeProvider()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-\(UUID().uuidString).flac")
        do {
            _ = try ChatCompletionsAudioHandler.buildRequest(job: job, provider: provider,
                                                             audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch ChatCompletionsAudioHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}

// URLProtocol stub that returns a fixed (Data, HTTPURLResponse) pair for
// every request and records the last URLRequest seen.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data)?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let (status, body) = Self.response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession(status: Int, body: Data) -> URLSession {
    StubProtocol.response = (status, body)
    StubProtocol.lastRequest = nil
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct ChatCompletionsAudioResponse {
    @Test func send_returnsContent_onSuccess() async throws {
        let json = #"{"choices":[{"message":{"content":"Hello world"}}]}"#
        let session = stubSession(status: 200, body: Data(json.utf8))
        let job = makeJob(prompt: "p")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        let text = try await ChatCompletionsAudioHandler.send(job: job, provider: provider,
                                                              audioURL: audio, apiKey: "k",
                                                              session: session)
        #expect(text == "Hello world")
    }

    @Test func send_throws_onNon200() async throws {
        let session = stubSession(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        let job = makeJob(prompt: "p")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        do {
            _ = try await ChatCompletionsAudioHandler.send(job: job, provider: provider,
                                                          audioURL: audio, apiKey: "k",
                                                          session: session)
            Issue.record("expected throw")
        } catch ChatCompletionsAudioHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }

    @Test func send_throws_whenChoicesMissing() async throws {
        let session = stubSession(status: 200, body: Data(#"{"unexpected":true}"#.utf8))
        let job = makeJob(prompt: "p")
        let provider = makeProvider()
        let audio = try writeAudio([0x01], ext: "flac")
        do {
            _ = try await ChatCompletionsAudioHandler.send(job: job, provider: provider,
                                                          audioURL: audio, apiKey: "k",
                                                          session: session)
            Issue.record("expected throw")
        } catch ChatCompletionsAudioHandler.SendError.malformedResponse(_) {
            // expected
        }
    }
}

@Suite struct ChatCompletionsAudioErrorDescription {
    @Test func httpError_describesStatusAndBody() {
        let e = ChatCompletionsAudioHandler.SendError.httpError(
            status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        #expect(e.localizedDescription.contains("401"))
        #expect(e.localizedDescription.contains("bad key"))
    }

    @Test func malformedResponse_describesBody() {
        let e = ChatCompletionsAudioHandler.SendError.malformedResponse(body: Data(#"{"unexpected":true}"#.utf8))
        #expect(e.localizedDescription.contains("unexpected"))
    }
}

@Suite struct ChatCompletionsAudioSession {
    @Test func defaultSession_usesGenerousRequestTimeout() {
        // Audio chat-completions uploads base64 audio and waits on the model, so
        // the 60s URLSession default is too short (same NSURLErrorTimedOut trap the
        // ElevenLabs handler hit). Wait generously instead.
        #expect(ChatCompletionsAudioHandler.requestTimeout >= 300)
        #expect(ChatCompletionsAudioHandler.defaultSession.configuration.timeoutIntervalForRequest
                == ChatCompletionsAudioHandler.requestTimeout)
    }
}
