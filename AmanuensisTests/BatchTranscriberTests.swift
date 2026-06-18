import XCTest
import DictationCore
import AudioPipelineJobs
@testable import Amanuensis

private struct StubHandler: AudioJobSending {
    let reply: String
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        reply
    }
}

private struct FakeKeychain: KeychainProviding {
    func get(account: String) async throws -> String { "fake-key" }
}

final class BatchTranscriberTests: XCTestCase {
    func testReturnsHandlerTextAsFinal() async throws {
        let provider = Provider(
            name: "Groq", presetID: "groq-whisper",
            baseURL: "https://api.groq.com/openai",
            apiKeyRef: KeychainRef(account: "groq"))
        let job = Job(
            name: "Dictation", providerID: provider.id,
            model: "whisper-large-v3-turbo", fields: [:], outputExt: "txt")
        let sut = BatchTranscriber(
            job: job, provider: provider, shape: .transcriptionMultipart,
            keychain: FakeKeychain(),
            handlers: [.transcriptionMultipart: StubHandler(reply: "hello there")])

        var final: String?
        try await sut.transcribe(
            audioFile: URL(fileURLWithPath: "/dev/null"),
            onPartial: { _ in }, onFinal: { final = $0 })
        XCTAssertEqual(final, "hello there")
    }
}
