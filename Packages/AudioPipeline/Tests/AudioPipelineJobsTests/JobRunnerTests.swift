import Foundation
import Testing
@testable import AudioPipelineJobs

// Fake keychain that returns a fixed key without touching Security.framework.
private actor FakeKeychain: KeychainProviding {
    let key: String
    init(key: String) { self.key = key }
    func get(account: String) async throws -> String { key }
}

private actor FakeHandler: AudioJobSending {
    private(set) var lastJob: Job?
    private(set) var lastProvider: Provider?
    private(set) var lastAudio: URL?
    private(set) var lastKey: String?
    private(set) var callCount = 0
    let result: Result<String, Error>
    init(result: Result<String, Error>) { self.result = result }
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String {
        lastJob = job; lastProvider = provider; lastAudio = audioURL; lastKey = apiKey
        callCount += 1
        return try result.get()
    }
}

private func makeProvider() -> Provider {
    Provider(name: "p", presetID: "openai-compat-chat",
             baseURL: "http://x", apiKeyRef: KeychainRef(account: "acc"))
}

private func makeJob(providerID: UUID, outputExt: String = "txt") -> Job {
    Job(name: "demo", providerID: providerID, model: "m",
        fields: ["prompt": "p"], outputExt: outputExt)
}

private func makeAudio() throws -> URL {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("combined.flac")
    try Data([0x01, 0x02]).write(to: url)
    return url
}

// Single-handler runner for the chat-shape behavioural tests.
private func chatRunner(keychain: any KeychainProviding, handler: any AudioJobSending) -> JobRunner {
    JobRunner(keychain: keychain, handlers: [.chatCompletionsAudio: handler])
}

@Suite struct JobRunnerBehavior {
    @Test func run_writesOutputFile_nextToRecording() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let keychain = FakeKeychain(key: "sk-x")
        let handler = FakeHandler(result: .success("transcribed text"))
        let runner = chatRunner(keychain: keychain, handler: handler)
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "transcribed text")
        #expect(outURL.lastPathComponent == "combined-demo.txt")
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }

    @Test func run_appendsConflictSuffix_whenOutputFileExists() async throws {
        let audio = try makeAudio()
        let folder = audio.deletingLastPathComponent()
        let existing = folder.appendingPathComponent("combined-demo.txt")
        try Data("prior".utf8).write(to: existing)

        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("new")))
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-demo (1).txt")
        let written = try String(contentsOf: outURL, encoding: .utf8)
        #expect(written == "new")
    }

    @Test func run_sanitisesSlashesAndColonsInJobName() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("x")))
        var job = makeJob(providerID: provider.id)
        job.name = "Folder/With:Bad chars"
        let outURL = try await runner.run(job: job, provider: provider,
                                          shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.lastPathComponent == "combined-Folder-With-Bad chars.txt")
    }

    @Test func run_fetchesKeyForProvidersAccount() async throws {
        let audio = try makeAudio()
        let keychain = FakeKeychain(key: "sk-real")
        let handler = FakeHandler(result: .success("ok"))
        let runner = chatRunner(keychain: keychain, handler: handler)
        let provider = makeProvider()
        let job = makeJob(providerID: provider.id)
        _ = try await runner.run(job: job, provider: provider,
                                 shape: .chatCompletionsAudio, audioURL: audio)
        #expect(await handler.lastKey == "sk-real")
        #expect(await handler.lastProvider?.id == provider.id)
        #expect(await handler.lastJob?.id == job.id)
        #expect(await handler.lastAudio == audio)
    }

    @Test func run_propagatesHandlerErrors() async throws {
        struct Boom: Error {}
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .failure(Boom())))
        do {
            _ = try await runner.run(job: makeJob(providerID: provider.id),
                                     provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
            Issue.record("expected throw")
        } catch is Boom {
            // expected
        }
    }

    @Test func run_writesToCustomFolder_whenOutputFolderPathSet() async throws {
        let audio = try makeAudio()
        let customFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("hello")))
        var job = makeJob(providerID: provider.id)
        job.outputFolderPath = customFolder.path
        let outURL = try await runner.run(job: job, provider: provider,
                                          shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.deletingLastPathComponent().path == customFolder.path)
        #expect(outURL.lastPathComponent == "combined-demo.txt")
    }

    @Test func run_writesNextToAudio_whenOutputFolderPathNil() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = chatRunner(keychain: FakeKeychain(key: "k"),
                                handler: FakeHandler(result: .success("hi")))
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .chatCompletionsAudio, audioURL: audio)
        #expect(outURL.deletingLastPathComponent() == audio.deletingLastPathComponent())
    }
}

@Suite struct JobRunnerDispatch {
    @Test func run_dispatchesToHandlerForShape() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let chat = FakeHandler(result: .success("chat"))
        let scribe = FakeHandler(result: .success("scribe"))
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handlers: [.chatCompletionsAudio: chat, .elevenLabsScribe: scribe])
        let outURL = try await runner.run(job: makeJob(providerID: provider.id),
                                          provider: provider, shape: .elevenLabsScribe, audioURL: audio)
        #expect(try String(contentsOf: outURL, encoding: .utf8) == "scribe")
        #expect(await scribe.callCount == 1)
        #expect(await chat.callCount == 0)
    }

    @Test func run_throwsUnsupportedShape_whenNoHandlerRegistered() async throws {
        let audio = try makeAudio()
        let provider = makeProvider()
        let runner = JobRunner(keychain: FakeKeychain(key: "k"),
                               handlers: [.chatCompletionsAudio: FakeHandler(result: .success("x"))])
        do {
            _ = try await runner.run(job: makeJob(providerID: provider.id),
                                     provider: provider, shape: .geminiGenerateContent, audioURL: audio)
            Issue.record("expected throw")
        } catch JobRunner.Error.unsupportedShape(let shape) {
            #expect(shape == .geminiGenerateContent)
        }
    }
}
