// LocalTranscriptionServiceTests.swift
import Foundation
import Testing
@testable import LocalTranscription

private func makeService() -> (LocalTranscriptionService, FakeEngine, FakeEngine) {
    let fa = FakeEngine(); let wk = FakeEngine()
    return (LocalTranscriptionService(fluidAudio: fa, whisperKit: wk, indicConformer: FakeEngine()), fa, wk)
}

@Test func routesWhisperModelToWhisperEngine() async throws {
    let (svc, fa, wk) = makeService()
    try await svc.download(modelID: "whisper-large-v3-turbo") { _ in }
    _ = try await svc.transcribe(audioURL: URL(fileURLWithPath: "/x.flac"), modelID: "whisper-large-v3-turbo", language: nil)
    #expect(await wk.lastTranscribedModel == "whisper-large-v3-turbo")
    #expect(await fa.lastTranscribedModel == nil)
}

@Test func routesParakeetToFluidAudioEngine() async throws {
    let (svc, fa, _) = makeService()
    try await svc.download(modelID: "parakeet-tdt-ctc-110m") { _ in }
    _ = try await svc.transcribe(audioURL: URL(fileURLWithPath: "/x.flac"), modelID: "parakeet-tdt-ctc-110m", language: nil)
    #expect(await fa.lastTranscribedModel == "parakeet-tdt-ctc-110m")
}

@Test func unknownModelThrows() async {
    let (svc, _, _) = makeService()
    await #expect(throws: LocalTranscriptionError.self) {
        _ = try await svc.transcribe(audioURL: URL(fileURLWithPath: "/x"), modelID: "nope", language: nil)
    }
}

@Test func routesIndicModelToIndicEngine() async throws {
    let indic = FakeEngine()
    try await indic.download(LocalModelCatalog.model(id: "indic-conformer-600m")!, progress: { _ in })
    let service = LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine(), indicConformer: indic)
    let text = try await service.transcribe(audioURL: URL(fileURLWithPath: "/x.wav"),
                                            modelID: "indic-conformer-600m", language: "hi")
    #expect(text == "fake transcript")
    #expect(await indic.lastTranscribedModel == "indic-conformer-600m")
}
