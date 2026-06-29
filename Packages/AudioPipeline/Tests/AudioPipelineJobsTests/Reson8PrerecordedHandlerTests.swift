import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "https://api.reson8.dev") -> Provider {
    Provider(name: "r8", presetID: "reson8",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "r8-key"))
}

private func makeJob(model: String = "", outputExt: String = "txt",
                     fields: [String: String] = [:]) -> Job {
    Job(name: "lesson", providerID: UUID(), model: model,
        fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8], name: String = "combined.flac") throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("r8-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

@Suite struct Reson8Request {
    @Test func buildsPOST_toPrerecordedPath() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/speech-to-text/prerecorded")
    }

    @Test func usesApiKeyAuthHeader_andOctetStreamContentType() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "secret")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "ApiKey secret")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test func body_isRawAudioBytes() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0xAA, 0xBB]), apiKey: "k")
        #expect(req.httpBody == Data([0xAA, 0xBB]))
    }

    @Test func emptyModel_isAllowed_noModelQuery() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(model: ""), provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        let query = req.url?.query ?? ""
        #expect(!query.contains("model="))
        #expect(!query.contains("custom_model_id="))
    }

    @Test func query_includesOptionalFields_whenSet() throws {
        let job = makeJob(fields: ["language": "en", "diarize": "true", "max_speakers": "3"])
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: job, provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        let query = try #require(req.url?.query)
        #expect(query.contains("language=en"))
        #expect(query.contains("diarize=true"))
        #expect(query.contains("max_speakers=3"))
    }

    @Test func query_omitsOptionalFields_whenEmptyOrAbsent() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(fields: ["language": ""]), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        let query = req.url?.query ?? ""
        #expect(!query.contains("language="))
        #expect(!query.contains("diarize="))
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let req = try Reson8PrerecordedHandler.buildRequest(
            job: makeJob(), provider: makeProvider(baseURL: "https://api.reson8.dev/"),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.path == "/v1/speech-to-text/prerecorded")
        #expect(req.url?.absoluteString.contains("//v1/speech-to-text") == false)
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try Reson8PrerecordedHandler.buildRequest(
                job: makeJob(), provider: makeProvider(), audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch Reson8PrerecordedHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}

@Suite struct Reson8Format {
    @Test func plainText_returnedForTextOutput() throws {
        let json = #"{"text":"the patient presented with chest pain"}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "the patient presented with chest pain")
    }

    @Test func diarized_rendersSpeakerLabelsInFirstSeenOrder() throws {
        let json = #"{"text":"where does it hurt my chest","segments":[{"text":"where does it hurt","speaker_id":0},{"text":"my chest","speaker_id":1}]}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: where does it hurt\nSpeaker 2: my chest")
    }

    @Test func diarized_mergesConsecutiveSameSpeakerSegments() throws {
        let json = #"{"text":"a b c","segments":[{"text":"a","speaker_id":2},{"text":"b","speaker_id":2},{"text":"c","speaker_id":5}]}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "Speaker 1: a b\nSpeaker 2: c")
    }

    @Test func segmentsWithoutSpeaker_returnFlatText() throws {
        let json = #"{"text":"flat text here","segments":[{"text":"flat text here"}]}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "txt")
        #expect(out == "flat text here")
    }

    @Test func jsonOutput_returnsPrettyRawResponse() throws {
        let json = #"{"text":"hi"}"#
        let out = try Reson8PrerecordedHandler.format(data: Data(json.utf8), outputExt: "json")
        #expect(out.contains("\"text\""))
        #expect(out.contains("\n"))   // pretty-printed
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try Reson8PrerecordedHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected malformedResponse")
        } catch Reson8PrerecordedHandler.SendError.malformedResponse {
            // expected
        }
    }
}

// URLProtocol stub local to the Reson8 send tests.
private final class Reson8StubProtocol: URLProtocol, @unchecked Sendable {
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

private func reson8StubSession(status: Int, body: Data) -> URLSession {
    Reson8StubProtocol.response = (status, body)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Reson8StubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct Reson8Send {
    @Test func send_returnsTranscript_onSuccess() async throws {
        let session = reson8StubSession(status: 200, body: Data(#"{"text":"hi there"}"#.utf8))
        let text = try await Reson8PrerecordedHandler.send(
            job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]),
            apiKey: "k", session: session)
        #expect(text == "hi there")
    }

    @Test func send_throws_onNon200() async throws {
        let session = reson8StubSession(status: 401, body: Data(#"{"err":"unauthorized"}"#.utf8))
        do {
            _ = try await Reson8PrerecordedHandler.send(
                job: makeJob(), provider: makeProvider(), audioURL: try writeAudio([0x01]),
                apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch Reson8PrerecordedHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }
}

@Suite struct Reson8ErrorDescription {
    @Test func httpError_describesStatusAndBody() {
        let e = Reson8PrerecordedHandler.SendError.httpError(
            status: 400, body: Data(#"{"err":"bad request"}"#.utf8))
        #expect(e.localizedDescription.contains("400"))
        #expect(e.localizedDescription.contains("bad request"))
    }
}

@Suite struct Reson8Shape {
    @Test func shape_hasPrerecordedPathHint() {
        #expect(JobShape.reson8Prerecorded.baseURLPathHint == "/v1/speech-to-text/prerecorded")
    }

    @Test func shape_exposesLanguageDiarizeMaxSpeakers() {
        let keys = Set(JobShape.reson8Prerecorded.fields.map(\.key))
        #expect(keys == ["language", "diarize", "max_speakers"])
    }
}

@Suite struct Reson8Dispatch {
    @Test func jobRunner_registersReson8Handler() {
        #expect(JobRunner.defaultHandlers[.reson8Prerecorded] != nil)
    }
}
