import Foundation
import Testing
@testable import LocalTranscription

private func svc() -> (LocalTranscriptionService, FakeEngine, FakeEngine) {
    let fa = FakeEngine(); let wk = FakeEngine()
    return (LocalTranscriptionService(fluidAudio: fa, whisperKit: wk), fa, wk)
}

@Test func preloadPinsResident() async throws {
    let (s, fa, _) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    #expect(await s.residentModelID() == "parakeet-tdt-ctc-110m")
    #expect(await fa.residentID == "parakeet-tdt-ctc-110m")
}

@Test func changingResidentUnloadsOld() async throws {
    let (s, fa, wk) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")   // FluidAudio
    try await s.preload(modelID: "whisper-large-v3-turbo")  // WhisperKit
    #expect(await s.residentModelID() == "whisper-large-v3-turbo")
    #expect(await fa.residentID == nil)                     // old engine unloaded
    #expect(await wk.residentID == "whisper-large-v3-turbo")
}

@Test func batchWithDifferentModelDoesNotEvictResident() async throws {
    let (s, fa, _) = svc()
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!) { _ in }
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-v3")!) { _ in }
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    _ = try await s.transcribe(audioURL: URL(fileURLWithPath: "/x"), modelID: "parakeet-tdt-v3", language: nil)
    #expect(await s.residentModelID() == "parakeet-tdt-ctc-110m")   // still pinned
    #expect(await fa.transientTranscribes == 1)
}

@Test func unloadResidentClears() async throws {
    let (s, fa, _) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    await s.unloadResident()
    #expect(await s.residentModelID() == nil)
    #expect(await fa.residentID == nil)
}

@Test func throwingPreloadLeavesNoResident() async throws {
    let (s, fa, wk) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")   // FluidAudio resident
    await wk.setPreloadShouldThrow(true)                     // next (WhisperKit) preload fails
    await #expect(throws: (any Error).self) { try await s.preload(modelID: "whisper-large-v3-turbo") }
    #expect(await s.residentModelID() == nil)               // consistent: old unloaded, new failed
    #expect(await fa.residentID == nil)
}

@Test func deletingResidentModelUnloadsIt() async throws {
    let (s, fa, _) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    try await s.delete(modelID: "parakeet-tdt-ctc-110m")
    #expect(await s.residentModelID() == nil)   // resident cleared
    #expect(await fa.residentID == nil)          // engine unloaded
}

@Test func deletingNonResidentModelKeepsResident() async throws {
    let (s, fa, _) = svc()
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")   // FluidAudio resident
    try await s.delete(modelID: "whisper-large-v3-turbo")   // delete a different model
    #expect(await s.residentModelID() == "parakeet-tdt-ctc-110m")   // still pinned
    #expect(await fa.residentID == "parakeet-tdt-ctc-110m")
}

@Test func sameModelTranscribeCountsAsReuse() async throws {
    let (s, fa, _) = svc()
    try await fa.download(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!) { _ in }
    try await s.preload(modelID: "parakeet-tdt-ctc-110m")
    _ = try await s.transcribe(audioURL: URL(fileURLWithPath: "/x"), modelID: "parakeet-tdt-ctc-110m", language: nil)
    #expect(await fa.reuseTranscribes == 1)
    #expect(await fa.transientTranscribes == 0)
}
