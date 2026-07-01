// LocalModelsStoreResidentTests.swift
import Foundation
import Testing
@testable import LocalTranscription

@MainActor @Test func preloadUpdatesResidentModelID() async {
    let store = LocalModelsStore(service: LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine()))
    await store.preload(modelID: "parakeet-tdt-ctc-110m")
    #expect(store.residentModelID == "parakeet-tdt-ctc-110m")
    await store.preload(modelID: nil)   // unload
    #expect(store.residentModelID == nil)
}
