import Foundation
import Testing
@testable import AudioPipelineJobs

// Fake keychain that returns a fixed key without touching Security.framework.
private actor FakeKeychain: KeychainProviding {
    let key: String
    init(key: String) { self.key = key }
    func get(account: String) async throws -> String { key }
}

private actor FakeHandler: ChatCompletionsAudioSending {
    private(set) var lastJob: Job?
    private(set) var lastAudio: URL?
    private(set) var lastKey: String?
    let result: Result<String, Error>
    init(result: Result<String, Error>) { self.result = result }
    func send(job: Job, audioURL: URL, apiKey: String) async throws -> String {
        lastJob = job; lastAudio = audioURL; lastKey = apiKey
        return try result.get()
    }
}

private func makeJob(outputExt: String = "txt") -> Job {
    Job(name: "demo", presetID: "openai-compat-chat",
        baseURL: "http://x", model: "m",
        apiKeyRef: KeychainRef(account: "acc"),
        fields: ["prompt": "p"], outputExt: outputExt)
}

private func makeAudio() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rec-\(UUID().uuidString).flac")
    try Data([0x01, 0x02]).write(to: url)
    return url
}

@Suite struct JobRunnerBehavior {
    @Test func run_writesOutputFile_nextToRecording() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-x")
        let handler = FakeHandler(result: .success("transcribed text"))
        let runner = JobRunner(keychain: keychain, handler: handler)
        let outURL = try await runner.run(job: makeJob(), audioURL: audio)
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "transcribed text")
        #expect(outURL.pathExtension == "txt")
        #expect(outURL.deletingPathExtension().lastPathComponent
                == audio.deletingPathExtension().lastPathComponent)
    }

    @Test func run_passesKeyAndJob_toHandler() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-real")
        let handler = FakeHandler(result: .success("ok"))
        let runner = JobRunner(keychain: keychain, handler: handler)
        let job = makeJob()
        _ = try await runner.run(job: job, audioURL: audio)
        #expect(await handler.lastKey == "sk-real")
        #expect(await handler.lastJob?.id == job.id)
        #expect(await handler.lastAudio == audio)
    }

    @Test func run_propagatesHandlerErrors() async throws {
        struct Boom: Error {}
        let audio = try makeAudio()
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handler: FakeHandler(result: .failure(Boom())))
        do {
            _ = try await runner.run(job: makeJob(), audioURL: audio)
            Issue.record("expected throw")
        } catch is Boom {
            // expected
        }
    }
}
