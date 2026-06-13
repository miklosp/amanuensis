import Foundation
import Testing
@testable import AudioPipelineJobs

// MARK: - Shared fixtures

private func makeProvider(baseURL: String = "https://api.soniox.com") -> Provider {
    Provider(name: "p", presetID: "soniox-async",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "soniox"))
}

private func makeJob(
    model: String = "stt-async-v4",
    diarization: String? = nil,
    languageHints: String? = nil,
    languageIdentification: String? = nil,
    context: String? = nil,
    outputExt: String = "txt"
) -> Job {
    var fields: [String: String] = [:]
    if let diarization { fields["enable_speaker_diarization"] = diarization }
    if let languageHints { fields["language_hints"] = languageHints }
    if let languageIdentification { fields["enable_language_identification"] = languageIdentification }
    if let context { fields["context"] = context }
    return Job(name: "t", providerID: UUID(), model: model, fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8]) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sx-audio-\(UUID().uuidString).flac")
    try Data(bytes).write(to: url)
    return url
}

// MARK: - Upload request

@Suite struct SonioxAsyncUploadRequest {
    @Test func buildsPOST_toFilesPath_withBearer_andMultipart() throws {
        let req = try SonioxAsyncHandler.buildUploadRequest(
            provider: makeProvider(), audioURL: try writeAudio([0x01, 0x02]), apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/files")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        let ct = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test func body_includesFilePart_withBytes() throws {
        let audio = try writeAudio([0xAA, 0xBB, 0xCC])
        let req = try SonioxAsyncHandler.buildUploadRequest(
            provider: makeProvider(), audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"file\"; filename=\"\(audio.lastPathComponent)\""))
        #expect(body.range(of: Data([0xAA, 0xBB, 0xCC])) != nil)
    }

    @Test func throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nope-\(UUID().uuidString).flac")
        do {
            _ = try SonioxAsyncHandler.buildUploadRequest(
                provider: makeProvider(), audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch SonioxAsyncHandler.BuildError.audioReadFailed {
            // expected
        }
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let req = try SonioxAsyncHandler.buildUploadRequest(
            provider: makeProvider(baseURL: "https://api.soniox.com/"),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/files")
    }
}

// MARK: - Create transcription request

@Suite struct SonioxAsyncCreateRequest {
    private func decodeBody(_ req: URLRequest) throws -> [String: Any] {
        let data = try #require(req.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func buildsPOST_toTranscriptionsPath_withModelAndFileID() throws {
        let req = try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(model: "stt-async-v4"), provider: makeProvider(), fileID: "file_9", apiKey: "k")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try decodeBody(req)
        #expect(body["model"] as? String == "stt-async-v4")
        #expect(body["file_id"] as? String == "file_9")
    }

    @Test func throws_missingModel_whenModelEmpty() throws {
        do {
            _ = try SonioxAsyncHandler.buildCreateRequest(
                job: makeJob(model: ""), provider: makeProvider(), fileID: "f", apiKey: "k")
            Issue.record("expected missingModel")
        } catch SonioxAsyncHandler.BuildError.missingModel {
            // expected
        }
    }

    @Test func omitsOptionalKeys_whenAbsent() throws {
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(), provider: makeProvider(), fileID: "f", apiKey: "k"))
        #expect(body["enable_speaker_diarization"] == nil)
        #expect(body["language_hints"] == nil)
        #expect(body["enable_language_identification"] == nil)
        #expect(body["context"] == nil)
    }

    @Test func mapsCheckboxesToBools_hintsToArray_contextToObject() throws {
        let job = makeJob(diarization: "true", languageHints: "en, es",
                          languageIdentification: "true", context: "Volvo, Skåne")
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: job, provider: makeProvider(), fileID: "f", apiKey: "k"))
        #expect(body["enable_speaker_diarization"] as? Bool == true)
        #expect(body["enable_language_identification"] as? Bool == true)
        #expect(body["language_hints"] as? [String] == ["en", "es"])
        let ctx = try #require(body["context"] as? [String: Any])
        #expect(ctx["text"] as? String == "Volvo, Skåne")
    }

    @Test func context_jsonObject_passedThroughVerbatim() throws {
        let json = #"{"general":[{"key":"domain","value":"B2B SaaS"}],"terms":["Petravich","Botkube"],"text":"interview context"}"#
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(context: json), provider: makeProvider(), fileID: "f", apiKey: "k"))
        let ctx = try #require(body["context"] as? [String: Any])
        #expect(ctx["text"] as? String == "interview context")
        #expect((ctx["terms"] as? [String])?.contains("Botkube") == true)
        let general = try #require(ctx["general"] as? [[String: Any]])
        #expect(general.first?["key"] as? String == "domain")
        // The raw JSON must NOT be double-encoded as a text string.
        #expect(ctx["text"] as? String != json)
    }

    @Test func context_plainProse_isWrappedAsText() throws {
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(context: "Bias toward Volvo and Skåne"), provider: makeProvider(),
            fileID: "f", apiKey: "k"))
        let ctx = try #require(body["context"] as? [String: Any])
        #expect(ctx["text"] as? String == "Bias toward Volvo and Skåne")
        #expect(ctx.count == 1)
    }

    @Test func context_wrappedObject_isUnwrapped() throws {
        let json = #"{"context":{"terms":["Petravich"]}}"#
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(context: json), provider: makeProvider(), fileID: "f", apiKey: "k"))
        let ctx = try #require(body["context"] as? [String: Any])
        #expect((ctx["terms"] as? [String])?.contains("Petravich") == true)
        #expect(ctx["context"] == nil)  // unwrapped, not nested under another "context"
    }

    @Test func diarizationFalse_emitsBoolFalse() throws {
        let body = try decodeBody(try SonioxAsyncHandler.buildCreateRequest(
            job: makeJob(diarization: "false"), provider: makeProvider(), fileID: "f", apiKey: "k"))
        #expect(body["enable_speaker_diarization"] as? Bool == false)
    }
}

// MARK: - Poll / transcript / delete requests

@Suite struct SonioxAsyncOtherRequests {
    @Test func pollRequest_isGET_toTranscriptionPath() throws {
        let req = try SonioxAsyncHandler.buildPollRequest(
            provider: makeProvider(), transcriptionID: "tx_7", apiKey: "k")
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions/tx_7")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func transcriptRequest_isGET_toTranscriptSubpath() throws {
        let req = try SonioxAsyncHandler.buildTranscriptRequest(
            provider: makeProvider(), transcriptionID: "tx_7", apiKey: "k")
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions/tx_7/transcript")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test func deleteTranscription_isDELETE() throws {
        let req = try SonioxAsyncHandler.buildDeleteTranscriptionRequest(
            provider: makeProvider(), transcriptionID: "tx_7", apiKey: "k")
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/transcriptions/tx_7")
    }

    @Test func deleteFile_isDELETE() throws {
        let req = try SonioxAsyncHandler.buildDeleteFileRequest(
            provider: makeProvider(), fileID: "file_3", apiKey: "k")
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.absoluteString == "https://api.soniox.com/v1/files/file_3")
    }
}

// MARK: - Output formatting

@Suite struct SonioxAsyncFormat {
    @Test func diarizedTokens_renderSpeakerLabels() throws {
        let data = Data(#"{"tokens":[{"text":" Hi","speaker":1},{"text":" there","speaker":1},{"text":" Bye","speaker":2}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "txt")
        #expect(out == "Speaker 1: Hi there\nSpeaker 2: Bye")
    }

    // Regression: the live Soniox transcript sends `speaker` as a numeric string,
    // which the old `Int?` decode rejected → malformedResponse on every diarized job.
    @Test func stringSpeaker_decodesAndRendersLabels() throws {
        let data = Data(#"{"id":"x","text":"Hi there Bye","tokens":[{"text":" Hi","speaker":"1"},{"text":" there","speaker":"1"},{"text":" Bye","speaker":"2"}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "txt")
        #expect(out == "Speaker 1: Hi there\nSpeaker 2: Bye")
    }

    // A token missing `text` must not fail the whole transcript decode.
    @Test func tokenMissingText_doesNotFailDecode() throws {
        let data = Data(#"{"tokens":[{"text":"Hello"},{},{"text":" world"}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "txt")
        #expect(out == "Hello world")
    }

    @Test func tokensWithoutSpeaker_renderPlainConcatenatedText() throws {
        let data = Data(#"{"tokens":[{"text":"Hello"},{"text":" world"}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "txt")
        #expect(out == "Hello world")
    }

    @Test func jsonOutput_prettyPrintsRaw() throws {
        let data = Data(#"{"tokens":[{"text":"Hi","speaker":1}]}"#.utf8)
        let out = try SonioxAsyncHandler.format(data: data, outputExt: "json")
        #expect(out.contains("\"tokens\""))
        #expect(out.contains("\n"))   // pretty-printed → multiline
    }

    @Test func malformedJSON_throwsMalformedResponse() throws {
        do {
            _ = try SonioxAsyncHandler.format(data: Data("not json".utf8), outputExt: "txt")
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.malformedResponse {
            // expected
        }
    }
}

// MARK: - send() orchestration

// Closure-routed URLProtocol stub: the test inspects (method, path) and returns
// (status, body). `pollCount` lets a test sequence "processing" → "completed".
final class SonioxStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var pollCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SonioxStubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct SonioxAsyncSend {
    @Test func send_uploadsCreatesPollsThenFormatsTranscript() async throws {
        SonioxStubProtocol.pollCount = 0
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"):
                return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"):
                return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"):
                SonioxStubProtocol.pollCount += 1
                let status = SonioxStubProtocol.pollCount >= 2 ? "completed" : "processing"
                return (200, Data("{\"status\":\"\(status)\"}".utf8))
            case ("GET", "/v1/transcriptions/tx_1/transcript"):
                return (200, Data(#"{"tokens":[{"text":" Hello","speaker":1},{"text":" world","speaker":1}]}"#.utf8))
            case ("DELETE", _):
                return (200, Data())
            default:
                return (404, Data())
            }
        }
        let text = try await SonioxAsyncHandler.send(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k",
            session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
        #expect(text == "Speaker 1: Hello world")
        #expect(SonioxStubProtocol.pollCount == 2)
    }

    @Test func send_throwsTranscriptionFailed_whenStatusError() async throws {
        SonioxStubProtocol.pollCount = 0
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"): return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"): return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"):
                return (200, Data(#"{"status":"error","error_message":"bad audio"}"#.utf8))
            case ("DELETE", _): return (200, Data())
            default: return (404, Data())
            }
        }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.transcriptionFailed(let message) {
            #expect(message == "bad audio")
        }
    }

    @Test func send_throwsTimedOut_whenNeverCompletes() async throws {
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"): return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"): return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"): return (200, Data(#"{"status":"processing"}"#.utf8))
            case ("DELETE", _): return (200, Data())
            default: return (404, Data())
            }
        }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .milliseconds(3))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.timedOut {
            // expected
        }
    }

    @Test func send_throwsHTTPError_whenUploadFails() async throws {
        SonioxStubProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.httpError(let status, _) {
            #expect(status == 401)
        }
    }

    @Test func send_throwsMalformedResponse_whenPollJSONUnparseable() async throws {
        SonioxStubProtocol.handler = { req in
            switch (req.httpMethod ?? "", req.url!.path) {
            case ("POST", "/v1/files"): return (200, Data(#"{"id":"file_1"}"#.utf8))
            case ("POST", "/v1/transcriptions"): return (200, Data(#"{"id":"tx_1"}"#.utf8))
            case ("GET", "/v1/transcriptions/tx_1"): return (200, Data(#"{"garbage":true}"#.utf8))
            case ("DELETE", _): return (200, Data())
            default: return (404, Data())
            }
        }
        do {
            _ = try await SonioxAsyncHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k",
                session: stubSession(), pollInterval: .milliseconds(1), deadline: .seconds(5))
            Issue.record("expected throw")
        } catch SonioxAsyncHandler.SendError.malformedResponse {
            // expected
        }
    }
}

@Suite struct SonioxAsyncSession {
    @Test func defaultSession_usesGenerousRequestTimeout() {
        #expect(SonioxAsyncHandler.requestTimeout >= 300)
        #expect(SonioxAsyncHandler.defaultSession.configuration.timeoutIntervalForRequest
                == SonioxAsyncHandler.requestTimeout)
    }
}

// MARK: - Dispatch registration

@Suite struct SonioxAsyncDispatch {
    @Test func jobRunner_registersSonioxAsyncHandler() {
        #expect(JobRunner.defaultHandlers[.sonioxAsync] != nil)
    }
}
