import Testing
import Foundation
import AudioPipelineJobs
@testable import LocalTranscription

// Minimal Provider fixture — no production stubs needed.
private let stubProvider = Provider(
    name: "Local",
    presetID: "local",
    baseURL: "https://local.test",
    apiKeyRef: KeychainRef(account: "")
)

@Test func senderTranscribesViaServiceUsingJobModel() async throws {
    let fa = FakeEngine()
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!) { _ in }
    let svc = LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine(), indicConformer: FakeEngine())
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft()
    job.model = "parakeet-tdt-ctc-110m"
    let text = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(text == "fake transcript")
}

@Test func senderResolvesMissingLanguageToModelDefault() async throws {
    // A batch IndicConformer job saved before the language picker existed carries no
    // language field. The sender must resolve it to the model's declared default so it
    // doesn't hard-fail the engine's language guard without the user opening the editor.
    let indic = FakeEngine()
    try await indic.download(LocalModelCatalog.model(id: "indic-conformer-600m")!) { _ in }
    let svc = LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine(), indicConformer: indic)
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft()
    job.model = "indic-conformer-600m"
    job.fields = [:]
    _ = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(await indic.lastLanguage == "hi")
}

@Test func senderDropsStaleLanguageForAutoDetectModel() async throws {
    // A stale Indic code carried onto an auto-detecting model must resolve to nil
    // (auto-detect) instead of being forwarded — the regression this PR review flagged.
    let fa = FakeEngine()
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-v3")!) { _ in }
    let svc = LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine(), indicConformer: FakeEngine())
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft()
    job.model = "parakeet-tdt-v3"
    job.fields = ["language": "ta"]
    _ = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(await fa.lastLanguage == nil)
}

@Test func senderPreservesSupportedExplicitLanguage() async throws {
    let indic = FakeEngine()
    try await indic.download(LocalModelCatalog.model(id: "indic-conformer-600m")!) { _ in }
    let svc = LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine(), indicConformer: indic)
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft()
    job.model = "indic-conformer-600m"
    job.fields = ["language": "bn"]
    _ = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(await indic.lastLanguage == "bn")
}

private struct SenderFakeTimedEngine: LocalTranscriptionEngine {
    let words: [TimedWord]
    func isDownloaded(_ model: LocalModel) async -> Bool { true }
    func installedBytes(_ model: LocalModel) async -> Int64 { 0 }
    func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func delete(_ model: LocalModel) async throws {}
    func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
    func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] { words }
}

private struct SenderFakeDiarizer: SpeakerDiarizing {
    let segments: [DiarizedSegment]
    func diarize(samples: [Float]) async throws -> [DiarizedSegment] { segments }
}

@Test func senderRoutesToDiarizedTranscriptWhenFlagIsSet() async throws {
    let words = [TimedWord(text: " hi", start: 0, end: 0.5), TimedWord(text: " yo", start: 2, end: 2.5)]
    let segs = [DiarizedSegment(speakerId: "S1", start: 0, end: 1), DiarizedSegment(speakerId: "S2", start: 1.5, end: 3)]
    let svc = LocalTranscriptionService(
        fluidAudio: FakeEngine(), whisperKit: SenderFakeTimedEngine(words: words), indicConformer: FakeEngine(),
        diarizer: SenderFakeDiarizer(segments: segs), loadSamples: { _ in [] })
    let sender = LocalTranscriptionSender(service: svc, diarize: true)
    var job = Job.makeDraft()
    job.model = "whisper-large-v3-turbo"
    let text = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(text == "Speaker 1: hi\nSpeaker 2: yo")
}

@Test func senderStaysPlainWhenDiarizeFlagIsOff() async throws {
    // Same engine/diarizer as the diarized case above — proves the plain path is
    // chosen because `diarize` defaults to false, not because timestamps are absent.
    let words = [TimedWord(text: " hi", start: 0, end: 0.5), TimedWord(text: " yo", start: 2, end: 2.5)]
    let segs = [DiarizedSegment(speakerId: "S1", start: 0, end: 1), DiarizedSegment(speakerId: "S2", start: 1.5, end: 3)]
    let svc = LocalTranscriptionService(
        fluidAudio: FakeEngine(), whisperKit: SenderFakeTimedEngine(words: words), indicConformer: FakeEngine(),
        diarizer: SenderFakeDiarizer(segments: segs), loadSamples: { _ in [] })
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft()
    job.model = "whisper-large-v3-turbo"
    let text = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(text == "hi yo")
}

@Test func senderRejectsUnknownModel() async throws {
    let sender = LocalTranscriptionSender(
        service: LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine(), indicConformer: FakeEngine())
    )
    var job = Job.makeDraft()
    job.model = "bogus"
    do {
        _ = try await sender.send(
            job: job, provider: stubProvider,
            audioURL: URL(fileURLWithPath: "/x"), apiKey: ""
        )
        Issue.record("Expected LocalTranscriptionError to be thrown")
    } catch is LocalTranscriptionError {
        // expected — guard throws before any suspension
    }
}
