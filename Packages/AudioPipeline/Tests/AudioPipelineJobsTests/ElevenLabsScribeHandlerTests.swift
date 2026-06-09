import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "https://api.elevenlabs.io") -> Provider {
    Provider(name: "el", presetID: "elevenlabs",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "el-key"))
}

private func makeJob(model: String = "scribe_v2", outputExt: String = "txt",
                     fields: [String: String] = [:]) -> Job {
    Job(name: "lesson", providerID: UUID(), model: model,
        fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8], name: String = "combined.flac") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("el-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

@Suite struct ElevenLabsScribeRequest {
    @Test func buildsPOST_toSpeechToTextPath() throws {
        let audio = try writeAudio([0x01, 0x02])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    }

    @Test func usesXiApiKeyHeader_andMultipartContentType() throws {
        let audio = try writeAudio([0x01])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi-secret")
        #expect(req.value(forHTTPHeaderField: "xi-api-key") == "xi-secret")
        let ct = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary=Boundary-"))
    }

    @Test func body_containsModelIdAndFilePart() throws {
        let audio = try writeAudio([0xAA, 0xBB])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(model: "scribe_v2"), provider: makeProvider(), audioURL: audio, apiKey: "xi")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model_id\""))
        #expect(body.contains("scribe_v2"))
        #expect(body.contains("name=\"file\"; filename=\"combined.flac\""))
        #expect(body.contains("Content-Type: audio/flac"))
        #expect(body.hasSuffix("--\r\n"))   // closing multipart boundary terminator
    }

    @Test func body_includesOptionalFields_whenSet() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["diarize": "true", "language_code": "sv", "num_speakers": "2"])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "xi")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"diarize\""))
        #expect(body.contains("name=\"language_code\""))
        #expect(body.contains("name=\"num_speakers\""))
    }

    @Test func body_omitsOptionalFields_whenEmptyOrAbsent() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["diarize": ""])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "xi")
        let body = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(!body.contains("name=\"diarize\""))
        #expect(!body.contains("name=\"language_code\""))
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let audio = try writeAudio([0x01])
        let req = try ElevenLabsScribeHandler.buildRequest(
            job: makeJob(), provider: makeProvider(baseURL: "https://api.elevenlabs.io/"),
            audioURL: audio, apiKey: "xi")
        #expect(req.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
    }

    @Test func throws_missingModel_whenModelEmpty() throws {
        let audio = try writeAudio([0x01])
        do {
            _ = try ElevenLabsScribeHandler.buildRequest(
                job: makeJob(model: ""), provider: makeProvider(), audioURL: audio, apiKey: "xi")
            Issue.record("expected missingModel")
        } catch ElevenLabsScribeHandler.BuildError.missingModel {
            // expected
        }
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try ElevenLabsScribeHandler.buildRequest(
                job: makeJob(), provider: makeProvider(), audioURL: missing, apiKey: "xi")
            Issue.record("expected audioReadFailed")
        } catch ElevenLabsScribeHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}

@Suite struct ElevenLabsScribeFormat {
    @Test func diarized_rendersSpeakerLabelsInFirstSeenOrder() throws {
        let json = """
        {"text":"Hello there hi",
         "words":[
           {"text":"Hello","type":"word","speaker_id":"speaker_0"},
           {"text":" ","type":"spacing","speaker_id":"speaker_0"},
           {"text":"there","type":"word","speaker_id":"speaker_0"},
           {"text":"hi","type":"word","speaker_id":"speaker_1"}]}
        """
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: Hello there\nSpeaker 2: hi")
    }

    @Test func leadingNilSpeakerWord_isDroppedNotPhantomLabelled() throws {
        let json = """
        {"text":"[MUSIC] Hello",
         "words":[
           {"text":"[MUSIC]","type":"audio_event","speaker_id":null},
           {"text":"Hello","type":"word","speaker_id":"speaker_0"}]}
        """
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: Hello")
    }

    @Test func wordsWithoutSpeakerIds_returnPlainText() throws {
        let json = #"{"text":"plain transcript","words":[{"text":"plain"},{"text":" transcript"}]}"#
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "plain transcript")
    }

    @Test func noWordsArray_returnsPlainText() throws {
        let json = #"{"text":"just text"}"#
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "just text")
    }

    @Test func jsonOutput_returnsPrettyRawResponse() throws {
        let json = #"{"text":"hi","language_code":"en","words":[{"text":"hi","speaker_id":"speaker_0"}]}"#
        let out = try ElevenLabsScribeHandler.format(data: Data(json.utf8), outputExt: "json")
        #expect(out.contains("\"language_code\""))   // snake_case preserved
        #expect(out.contains("\"speaker_id\""))
        #expect(out.contains("\n"))                   // pretty-printed
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try ElevenLabsScribeHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected malformedResponse")
        } catch ElevenLabsScribeHandler.SendError.malformedResponse {
            // expected
        }
    }
}

// URLProtocol stub local to the ElevenLabs send tests.
private final class ScribeStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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

private func scribeStubSession(status: Int, body: Data) -> URLSession {
    ScribeStubProtocol.response = (status, body)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ScribeStubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct ElevenLabsScribeSend {
    @Test func send_returnsLabelledTranscript_onSuccess() async throws {
        let json = #"{"text":"hi","words":[{"text":"hi","speaker_id":"speaker_0"}]}"#
        let session = scribeStubSession(status: 200, body: Data(json.utf8))
        let audio = try writeAudio([0x01])
        let text = try await ElevenLabsScribeHandler.send(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi", session: session)
        #expect(text == "Speaker 1: hi")
    }

    @Test func send_throws_onNon200() async throws {
        let session = scribeStubSession(status: 401, body: Data(#"{"detail":"unauthorized"}"#.utf8))
        let audio = try writeAudio([0x01])
        do {
            _ = try await ElevenLabsScribeHandler.send(
                job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi", session: session)
            Issue.record("expected throw")
        } catch ElevenLabsScribeHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }

    @Test func send_throws_onMalformedJSON() async throws {
        let session = scribeStubSession(status: 200, body: Data("not json".utf8))
        let audio = try writeAudio([0x01])
        do {
            _ = try await ElevenLabsScribeHandler.send(
                job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "xi", session: session)
            Issue.record("expected throw")
        } catch ElevenLabsScribeHandler.SendError.malformedResponse {
            // expected
        }
    }
}

@Suite struct ElevenLabsScribeSession {
    @Test func defaultSession_usesGenerousRequestTimeout() {
        // ElevenLabs synchronous STT holds the connection while transcribing and
        // sends no bytes until done, so the 60s URLSession default aborts real
        // recordings with NSURLErrorTimedOut (-1001). Wait generously instead.
        #expect(ElevenLabsScribeHandler.requestTimeout >= 300)
        #expect(ElevenLabsScribeHandler.defaultSession.configuration.timeoutIntervalForRequest
                == ElevenLabsScribeHandler.requestTimeout)
    }
}
