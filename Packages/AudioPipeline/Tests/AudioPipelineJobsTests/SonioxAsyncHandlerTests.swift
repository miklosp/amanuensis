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
