import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeJob(prompt: String, model: String = "gemini-flash",
                     baseURL: String = "http://localhost:4444/openai",
                     audioFormat: String? = nil,
                     temperature: String? = nil) -> Job {
    var fields: [String: String] = ["prompt": prompt]
    if let audioFormat { fields["audio_format"] = audioFormat }
    if let temperature { fields["temperature"] = temperature }
    return Job(name: "t", presetID: "openai-compat-chat",
               baseURL: baseURL, model: model,
               apiKeyRef: KeychainRef(account: "bifrost"),
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
        let audio = try writeAudio([0x01, 0x02], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://localhost:4444/openai/v1/chat/completions")
    }

    @Test func authorizationHeader_isBearerToken() throws {
        let job = makeJob(prompt: "Hello")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "sk-x")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func body_encodesModelMessagesAndBase64Audio() throws {
        let job = makeJob(prompt: "Transcribe.")
        let audio = try writeAudio([0xAA, 0xBB, 0xCC], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
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
        let audio = try writeAudio([0x01], ext: "wav")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
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
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["temperature"] as? Double == 0.3)
    }

    @Test func temperature_isOmittedWhenAbsent() throws {
        let job = makeJob(prompt: "p")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["temperature"] == nil)
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let job = makeJob(prompt: "p", baseURL: "http://example.com/")
        let audio = try writeAudio([0x01], ext: "flac")
        let req = try ChatCompletionsAudioHandler.buildRequest(job: job, audioURL: audio, apiKey: "k")
        #expect(req.url?.absoluteString == "http://example.com/v1/chat/completions")
    }
}
