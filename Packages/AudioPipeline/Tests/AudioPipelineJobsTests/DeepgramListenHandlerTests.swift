import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "https://api.deepgram.com") -> Provider {
    Provider(name: "dg", presetID: "deepgram",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "dg-key"))
}

private func makeJob(model: String = "nova-3", outputExt: String = "txt",
                     fields: [String: String] = [:]) -> Job {
    Job(name: "lesson", providerID: UUID(), model: model,
        fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8], name: String = "combined.flac") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

@Suite struct DeepgramListenRequest {
    @Test func buildsPOST_toListenPath_withModelQuery() throws {
        let audio = try writeAudio([0x01, 0x02])
        let req = try DeepgramListenHandler.buildRequest(
            job: makeJob(model: "nova-3"), provider: makeProvider(), audioURL: audio, apiKey: "k")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/listen")
        #expect(req.url?.query?.contains("model=nova-3") == true)
    }

    @Test func usesTokenAuthHeader_andAudioContentType() throws {
        let audio = try writeAudio([0x01])
        let req = try DeepgramListenHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "secret")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Token secret")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "audio/flac")
    }

    @Test func body_isRawAudioBytes() throws {
        let audio = try writeAudio([0xAA, 0xBB, 0xCC])
        let req = try DeepgramListenHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "k")
        #expect(req.httpBody == Data([0xAA, 0xBB, 0xCC]))
    }

    @Test func query_includesOptionalFields_whenSet() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["diarize": "true", "language": "en", "smart_format": "true"])
        let req = try DeepgramListenHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "k")
        let query = try #require(req.url?.query)
        #expect(query.contains("diarize=true"))
        #expect(query.contains("language=en"))
        #expect(query.contains("smart_format=true"))
    }

    @Test func query_omitsOptionalFields_whenEmptyOrAbsent() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["language": ""])
        let req = try DeepgramListenHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "k")
        let query = req.url?.query ?? ""
        #expect(!query.contains("language="))
        #expect(!query.contains("diarize="))
    }

    @Test func query_splitsKeytermOnCommas() throws {
        let audio = try writeAudio([0x01])
        let job = makeJob(fields: ["keyterm": "Kubernetes, Anthropic"])
        let req = try DeepgramListenHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: audio, apiKey: "k")
        let query = try #require(req.url?.query)
        #expect(query.contains("keyterm=Kubernetes"))
        #expect(query.contains("keyterm=Anthropic"))
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let audio = try writeAudio([0x01])
        let req = try DeepgramListenHandler.buildRequest(
            job: makeJob(), provider: makeProvider(baseURL: "https://api.deepgram.com/"),
            audioURL: audio, apiKey: "k")
        #expect(req.url?.path == "/v1/listen")
        #expect(req.url?.absoluteString.contains("//v1/listen") == false)
    }

    @Test func throws_missingModel_whenModelEmpty() throws {
        let audio = try writeAudio([0x01])
        do {
            _ = try DeepgramListenHandler.buildRequest(
                job: makeJob(model: ""), provider: makeProvider(), audioURL: audio, apiKey: "k")
            Issue.record("expected missingModel")
        } catch DeepgramListenHandler.BuildError.missingModel {
            // expected
        }
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try DeepgramListenHandler.buildRequest(
                job: makeJob(), provider: makeProvider(), audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch DeepgramListenHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}

@Suite struct DeepgramListenFormat {
    private static let sample = #"""
    {"results":{"channels":[{"alternatives":[{"transcript":"hello world","confidence":0.98}]}]}}
    """#

    @Test func transcript_returnedForTextOutput() throws {
        let out = try DeepgramListenHandler.format(data: Data(Self.sample.utf8), outputExt: "txt")
        #expect(out == "hello world")
    }

    @Test func diarized_rendersSpeakerLabelsInFirstSeenOrder() throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"hello there general kenobi","words":[{"word":"hello","speaker":0,"punctuated_word":"Hello"},{"word":"there","speaker":0,"punctuated_word":"there"},{"word":"general","speaker":1,"punctuated_word":"General"},{"word":"kenobi","speaker":1,"punctuated_word":"Kenobi"}]}]}]}}"#
        let out = try DeepgramListenHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: Hello there\nSpeaker 2: General Kenobi")
    }

    @Test func diarized_prefersPunctuatedWord() throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"hello","words":[{"word":"hello","speaker":0,"punctuated_word":"Hello,"}]}]}]}}"#
        let out = try DeepgramListenHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: Hello,")
    }

    @Test func wordsWithoutSpeaker_returnFlatTranscript() throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"flat text here","words":[{"word":"flat"},{"word":"text"},{"word":"here"}]}]}]}}"#
        let out = try DeepgramListenHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "flat text here")
    }

    @Test func jsonOutput_returnsPrettyRawResponse() throws {
        let out = try DeepgramListenHandler.format(data: Data(Self.sample.utf8), outputExt: "json")
        #expect(out.contains("\"transcript\""))
        #expect(out.contains("\n"))   // pretty-printed
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try DeepgramListenHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected malformedResponse")
        } catch DeepgramListenHandler.SendError.malformedResponse {
            // expected
        }
    }

    @Test func emptyChannels_throwsMalformedResponse() throws {
        let json = #"{"results":{"channels":[]}}"#
        do {
            _ = try DeepgramListenHandler.format(data: Data(json.utf8), outputExt: "txt")
            Issue.record("expected malformedResponse")
        } catch DeepgramListenHandler.SendError.malformedResponse {
            // expected
        }
    }
}

// URLProtocol stub local to the Deepgram send tests.
private final class DeepgramStubProtocol: URLProtocol, @unchecked Sendable {
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

private func deepgramStubSession(status: Int, body: Data) -> URLSession {
    DeepgramStubProtocol.response = (status, body)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DeepgramStubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct DeepgramListenSend {
    @Test func send_returnsTranscript_onSuccess() async throws {
        let json = #"{"results":{"channels":[{"alternatives":[{"transcript":"hi there"}]}]}}"#
        let session = deepgramStubSession(status: 200, body: Data(json.utf8))
        let audio = try writeAudio([0x01])
        let text = try await DeepgramListenHandler.send(
            job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "k", session: session)
        #expect(text == "hi there")
    }

    @Test func send_throws_onNon200() async throws {
        let session = deepgramStubSession(status: 401, body: Data(#"{"err":"unauthorized"}"#.utf8))
        let audio = try writeAudio([0x01])
        do {
            _ = try await DeepgramListenHandler.send(
                job: makeJob(), provider: makeProvider(), audioURL: audio, apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch DeepgramListenHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }
}

@Suite struct DeepgramListenErrorDescription {
    @Test func httpError_describesStatusAndBody() {
        let e = DeepgramListenHandler.SendError.httpError(
            status: 400, body: Data(#"{"err":"bad keyterm"}"#.utf8))
        #expect(e.localizedDescription.contains("400"))
        #expect(e.localizedDescription.contains("bad keyterm"))
    }
}

@Suite struct DeepgramListenShape {
    @Test func shape_hasListenPathHint() {
        #expect(JobShape.deepgramListen.baseURLPathHint == "/v1/listen")
    }

    @Test func shape_exposesKeytermAndOptions() {
        let keys = Set(JobShape.deepgramListen.fields.map(\.key))
        #expect(keys.contains("keyterm"))
        #expect(keys.contains("diarize"))
        #expect(keys.contains("language"))
    }
}
