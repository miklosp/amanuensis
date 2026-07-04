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
