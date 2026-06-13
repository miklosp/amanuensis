import Foundation
import Testing
@testable import AudioPipelineJobs

private func makeProvider(baseURL: String = "http://localhost:4444/openai") -> Provider {
    Provider(name: "p", presetID: "groq-whisper",
             baseURL: baseURL, apiKeyRef: KeychainRef(account: "bifrost"))
}

private func makeJob(model: String = "whisper-large-v3-turbo",
                     language: String? = nil,
                     prompt: String? = nil,
                     temperature: String? = nil,
                     responseFormat: String? = nil,
                     outputExt: String = "txt") -> Job {
    var fields: [String: String] = [:]
    if let language { fields["language"] = language }
    if let prompt { fields["prompt"] = prompt }
    if let temperature { fields["temperature"] = temperature }
    if let responseFormat { fields["response_format"] = responseFormat }
    return Job(name: "t", providerID: UUID(), model: model,
               fields: fields, outputExt: outputExt)
}

private func writeAudio(_ bytes: [UInt8], ext: String = "flac") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tx-audio-\(UUID().uuidString).\(ext)")
    try Data(bytes).write(to: url)
    return url
}

@Suite struct TranscriptionMultipartRequest {
    @Test func buildsPOST_toTranscriptionsPath() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01, 0x02]), apiKey: "sk-x")
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "http://localhost:4444/openai/v1/audio/transcriptions")
    }

    @Test func authorizationHeader_isBearerToken_andMultipartContentType() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "sk-x")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        let ct = try #require(req.value(forHTTPHeaderField: "Content-Type"))
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test func body_includesModelAndFileParts() throws {
        let audio = try writeAudio([0xAA, 0xBB, 0xCC])
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(model: "whisper-1"), provider: makeProvider(),
            audioURL: audio, apiKey: "k")
        let body = try #require(req.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"model\""))
        #expect(text.contains("whisper-1"))
        #expect(text.contains("name=\"file\"; filename=\"\(audio.lastPathComponent)\""))
        #expect(text.contains("Content-Type: audio/flac"))
        #expect(body.range(of: Data([0xAA, 0xBB, 0xCC])) != nil)
    }

    @Test func optionalFields_includedWhenSet() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(language: "sv", prompt: "Volvo, Skåne",
                         temperature: "0.2", responseFormat: "verbose_json"),
            provider: makeProvider(), audioURL: try writeAudio([0x01]), apiKey: "k")
        let text = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(text.contains("name=\"language\""))
        #expect(text.contains("sv"))
        #expect(text.contains("name=\"prompt\""))
        #expect(text.contains("Volvo, Skåne"))
        #expect(text.contains("name=\"temperature\""))
        #expect(text.contains("name=\"response_format\""))
        #expect(text.contains("verbose_json"))
    }

    @Test func optionalFields_omittedWhenAbsent() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        let text = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(!text.contains("name=\"language\""))
        #expect(!text.contains("name=\"prompt\""))
        #expect(!text.contains("name=\"temperature\""))
        #expect(!text.contains("name=\"response_format\""))
    }

    @Test func trailingSlashInBaseURL_isHandled() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(), provider: makeProvider(baseURL: "http://example.com/"),
            audioURL: try writeAudio([0x01]), apiKey: "k")
        #expect(req.url?.absoluteString == "http://example.com/v1/audio/transcriptions")
    }

    @Test func buildRequest_throws_missingModel_whenModelEmpty() throws {
        let audio = try writeAudio([0x01])
        do {
            _ = try TranscriptionMultipartHandler.buildRequest(
                job: makeJob(model: ""), provider: makeProvider(),
                audioURL: audio, apiKey: "k")
            Issue.record("expected missingModel")
        } catch TranscriptionMultipartHandler.BuildError.missingModel {
            // expected
        }
    }

    @Test func buildRequest_throws_audioReadFailed_whenFileMissing() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-\(UUID().uuidString).flac")
        do {
            _ = try TranscriptionMultipartHandler.buildRequest(
                job: makeJob(), provider: makeProvider(),
                audioURL: missing, apiKey: "k")
            Issue.record("expected audioReadFailed")
        } catch TranscriptionMultipartHandler.BuildError.audioReadFailed {
            // expected
        }
    }
}

// URLProtocol stub local to this file so it doesn't share static state with
// the ChatCompletions response tests (which would race under parallel runs).
final class TranscriptionStubProtocol: URLProtocol, @unchecked Sendable {
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

private func stubSession(status: Int, body: Data) -> URLSession {
    TranscriptionStubProtocol.response = (status, body)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TranscriptionStubProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct TranscriptionMultipartResponse {
    @Test func send_returnsText_whenResponseFormatUnset() async throws {
        let session = stubSession(status: 200, body: Data(#"{"text":"Hello world"}"#.utf8))
        let text = try await TranscriptionMultipartHandler.send(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
        #expect(text == "Hello world")
    }

    @Test func send_returnsText_whenResponseFormatJSON() async throws {
        let session = stubSession(status: 200, body: Data(#"{"text":"Hej"}"#.utf8))
        let text = try await TranscriptionMultipartHandler.send(
            job: makeJob(responseFormat: "json"), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
        #expect(text == "Hej")
    }

    @Test func send_returnsRawBody_forVerboseJSON() async throws {
        let raw = #"{"text":"Hi","segments":[{"id":0}]}"#
        let session = stubSession(status: 200, body: Data(raw.utf8))
        let text = try await TranscriptionMultipartHandler.send(
            job: makeJob(responseFormat: "verbose_json"), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
        #expect(text == raw)
    }

    @Test func send_returnsRawBody_forSRT() async throws {
        let raw = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
        let session = stubSession(status: 200, body: Data(raw.utf8))
        let text = try await TranscriptionMultipartHandler.send(
            job: makeJob(responseFormat: "srt"), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
        #expect(text == raw)
    }

    @Test func send_returnsRawBody_forText() async throws {
        let raw = "Just the words.\n"
        let session = stubSession(status: 200, body: Data(raw.utf8))
        let text = try await TranscriptionMultipartHandler.send(
            job: makeJob(responseFormat: "text"), provider: makeProvider(),
            audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
        #expect(text == raw)
    }

    @Test func send_throws_onNon200() async throws {
        let session = stubSession(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        do {
            _ = try await TranscriptionMultipartHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch TranscriptionMultipartHandler.SendError.httpError(let code, _) {
            #expect(code == 401)
        }
    }

    @Test func send_throws_whenJSONMissingText() async throws {
        let session = stubSession(status: 200, body: Data(#"{"unexpected":true}"#.utf8))
        do {
            _ = try await TranscriptionMultipartHandler.send(
                job: makeJob(), provider: makeProvider(),
                audioURL: try writeAudio([0x01]), apiKey: "k", session: session)
            Issue.record("expected throw")
        } catch TranscriptionMultipartHandler.SendError.malformedResponse(_) {
            // expected
        }
    }

    @Test func send_compressesOversizeAudio_andCleansUpTemp() async throws {
        let audio = try writeBytes(2_000)
        let session = stubSession(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        nonisolated(unsafe) var tempURL: URL?
        let text = try await TranscriptionMultipartHandler.send(
            job: makeJob(), provider: makeProvider(), audioURL: audio,
            apiKey: "k", session: session, maxBytes: 1_000,
            compress: { _, dest in
                tempURL = dest
                try Data([0xAA]).write(to: dest)
            })
        #expect(text == "ok")
        // The compressed temp file the handler created must be removed afterwards.
        let temp = try #require(tempURL)
        #expect(temp.pathExtension == "m4a")
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
}

@Suite struct TranscriptionMultipartErrorDescription {
    @Test func httpError_describesStatusAndBody() {
        let e = TranscriptionMultipartHandler.SendError.httpError(
            status: 413, body: Data(#"{"error":"file too large"}"#.utf8))
        #expect(e.localizedDescription.contains("413"))
        #expect(e.localizedDescription.contains("file too large"))
    }

    @Test func malformedResponse_describesBody() {
        let e = TranscriptionMultipartHandler.SendError.malformedResponse(body: Data("not json".utf8))
        #expect(e.localizedDescription.contains("not json"))
    }
}

@Suite struct TranscriptionMultipartSession {
    @Test func defaultSession_usesGenerousRequestTimeout() {
        #expect(TranscriptionMultipartHandler.requestTimeout >= 300)
        #expect(TranscriptionMultipartHandler.defaultSession.configuration.timeoutIntervalForRequest
                == TranscriptionMultipartHandler.requestTimeout)
    }
}

@Suite struct TranscriptionMultipartDispatch {
    @Test func jobRunner_registersTranscriptionMultipartHandler() {
        #expect(JobRunner.defaultHandlers[.transcriptionMultipart] != nil)
    }
}

private func writeBytes(_ count: Int, ext: String = "flac") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sized-\(UUID().uuidString).\(ext)")
    try Data(count: count).write(to: url)
    return url
}

@Suite struct TranscriptionMultipartPrepareUpload {
    @Test func smallFile_isUploadedAsIs_withoutCompressing() async throws {
        let audio = try writeBytes(1_000)
        nonisolated(unsafe) var compressCalled = false
        let prepared = try await TranscriptionMultipartHandler.prepareUpload(
            audioURL: audio, maxBytes: 24 * 1024 * 1024,
            compress: { _, _ in compressCalled = true })
        #expect(prepared.url == audio)
        #expect(prepared.isTemporary == false)
        #expect(compressCalled == false)
    }

    @Test func oversizeFile_isCompressedToTempM4A() async throws {
        let audio = try writeBytes(2_000)
        nonisolated(unsafe) var receivedSource: URL?
        nonisolated(unsafe) var receivedDest: URL?
        let prepared = try await TranscriptionMultipartHandler.prepareUpload(
            audioURL: audio, maxBytes: 1_000,
            compress: { source, dest in
                receivedSource = source
                receivedDest = dest
                try Data([0x01, 0x02]).write(to: dest)  // stand in for the encoder
            })
        #expect(prepared.isTemporary == true)
        #expect(prepared.url.pathExtension == "m4a")
        #expect(receivedSource == audio)
        #expect(receivedDest == prepared.url)
        #expect(FileManager.default.fileExists(atPath: prepared.url.path))
        try? FileManager.default.removeItem(at: prepared.url)
    }
}

@Suite struct TranscriptionMultipartContentType {
    @Test func filePart_contentType_flac() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01], ext: "flac"), apiKey: "k")
        let text = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(text.contains("Content-Type: audio/flac"))
    }

    @Test func filePart_contentType_m4a() throws {
        let req = try TranscriptionMultipartHandler.buildRequest(
            job: makeJob(), provider: makeProvider(),
            audioURL: try writeAudio([0x01], ext: "m4a"), apiKey: "k")
        let text = String(decoding: try #require(req.httpBody), as: UTF8.self)
        #expect(text.contains("Content-Type: audio/mp4"))
    }
}
