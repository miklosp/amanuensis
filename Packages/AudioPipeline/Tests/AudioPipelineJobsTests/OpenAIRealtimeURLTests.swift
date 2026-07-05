// OpenAIRealtimeURLTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct OpenAIRealtimeURLBuilding {
    @Test func swapsHttpsToWss_appendsPath_andTranscriptionIntent() throws {
        let url = try OpenAIRealtimeURL.make(baseURL: "https://api.openai.com")
        #expect(url.scheme == "wss")
        #expect(url.host == "api.openai.com")
        #expect(url.path == "/v1/realtime")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.contains(URLQueryItem(name: "intent", value: "transcription")))
    }

    @Test func trimsTrailingSlashOnBaseURL() throws {
        let url = try OpenAIRealtimeURL.make(baseURL: "https://api.openai.com/")
        #expect(url.path == "/v1/realtime")
    }

    @Test func usesWsForLoopbackHttp() throws {
        let url = try OpenAIRealtimeURL.make(baseURL: "http://127.0.0.1:8080")
        #expect(url.scheme == "ws")
    }

    @Test func rejectsSchemelessBaseURL() {
        #expect(throws: OpenAIRealtimeURL.BuildError.self) {
            _ = try OpenAIRealtimeURL.make(baseURL: "api.openai.com")
        }
    }
}

@Suite struct OpenAIRealtimeConfigBuilding {
    private func object(_ json: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    @Test func buildsTranscriptionSessionUpdate() throws {
        let obj = try object(OpenAIRealtimeConfig.sessionUpdate(.init()))
        #expect(obj["type"] as? String == "session.update")
        let session = obj["session"] as! [String: Any]
        #expect(session["type"] as? String == "transcription")
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]

        let format = input["format"] as! [String: Any]
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 16_000)

        let transcription = input["transcription"] as! [String: Any]
        #expect(transcription["model"] as? String == "gpt-4o-transcribe")
        #expect(transcription["language"] as? String == "en")

        let turn = input["turn_detection"] as! [String: Any]
        #expect(turn["type"] as? String == "server_vad")
    }

    @Test func languageAndModelOverridesPassThrough() throws {
        let opts = OpenAIRealtimeOptions(model: "gpt-4o-mini-transcribe", language: "es")
        let obj = try object(OpenAIRealtimeConfig.sessionUpdate(opts))
        let input = ((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        #expect(transcription["language"] as? String == "es")
    }

    @Test func serverVADOffOmitsTurnDetection() throws {
        let opts = OpenAIRealtimeOptions(serverVAD: false)
        let obj = try object(OpenAIRealtimeConfig.sessionUpdate(opts))
        let input = ((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any]
        #expect(input["turn_detection"] == nil)
    }
}
