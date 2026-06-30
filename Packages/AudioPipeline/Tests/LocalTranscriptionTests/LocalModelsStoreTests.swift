// LocalModelsStoreTests.swift
import Foundation
import Testing
@testable import LocalTranscription

@MainActor @Test func downloadThenDeleteUpdatesState() async {
    let svc = LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine())
    let store = LocalModelsStore(service: svc)
    let model = LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!

    await store.download(model)
    #expect(store.states["parakeet-tdt-ctc-110m"]?.isDownloaded == true)
    #expect(store.states["parakeet-tdt-ctc-110m"]?.isDownloading == false)
    #expect((store.states["parakeet-tdt-ctc-110m"]?.progress ?? 0) == 1.0)

    await store.delete(model)
    #expect(store.states["parakeet-tdt-ctc-110m"]?.isDownloaded == false)
}
