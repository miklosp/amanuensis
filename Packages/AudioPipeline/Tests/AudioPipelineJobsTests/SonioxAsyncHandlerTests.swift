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
