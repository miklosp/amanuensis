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
    let svc = LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine())
    let sender = LocalTranscriptionSender(service: svc)
    var job = Job.makeDraft()
    job.model = "parakeet-tdt-ctc-110m"
    let text = try await sender.send(
        job: job, provider: stubProvider,
        audioURL: URL(fileURLWithPath: "/x.flac"), apiKey: ""
    )
    #expect(text == "fake transcript")
}

@Test func senderRejectsUnknownModel() async throws {
    let sender = LocalTranscriptionSender(
        service: LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine())
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
