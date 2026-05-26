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
    // Each call gets its own subfolder so output-file naming is deterministic
    // across parallel-test runs (the runner writes "combined-<name>.<ext>"
    // into the audio's parent folder).
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("combined.flac")
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
        #expect(outURL.lastPathComponent == "combined-demo.txt")
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }

    @Test func run_appendsConflictSuffix_whenOutputFileExists() async throws {
        let audio = try makeAudio()
        let folder = audio.deletingLastPathComponent()
        // Pre-create the canonical output to force conflict resolution.
        let existing = folder.appendingPathComponent("combined-demo.txt")
        try Data("prior".utf8).write(to: existing)

        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("new"))
        )
        let outURL = try await runner.run(job: makeJob(), audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-demo (1).txt")
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "new")
    }

    @Test func run_sanitisesSlashesAndColonsInJobName() async throws {
        let audio = try makeAudio()
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("x"))
        )
        var job = makeJob()
        job.name = "Folder/With:Bad chars"
        let outURL = try await runner.run(job: job, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-Folder-With-Bad chars.txt")
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

    @Test func run_writesToCustomFolder_whenOutputFolderPathSet() async throws {
        let audio = try makeAudio()
        let customFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        // Don't pre-create; runner should create it.
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("hello"))
        )
        var job = makeJob()
        job.outputFolderPath = customFolder.path
        let outURL = try await runner.run(job: job, audioURL: audio)
        #expect(outURL.deletingLastPathComponent().path == customFolder.path)
        #expect(outURL.lastPathComponent == "combined-demo.txt")
    }

    @Test func run_writesNextToAudio_whenOutputFolderPathNil() async throws {
        let audio = try makeAudio()
        let runner = JobRunner(
            keychain: FakeKeychain(key: "k"),
            handler: FakeHandler(result: .success("hi"))
        )
        let outURL = try await runner.run(job: makeJob(), audioURL: audio)
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }
}
