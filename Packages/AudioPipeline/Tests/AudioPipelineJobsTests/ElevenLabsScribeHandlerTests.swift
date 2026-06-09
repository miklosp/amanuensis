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
