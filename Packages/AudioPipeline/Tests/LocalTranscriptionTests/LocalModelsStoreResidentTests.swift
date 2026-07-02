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

@MainActor @Test func preloadExposesLoadingModelIDWhileInFlight() async {
    let fa = FakeEngine()
    let store = LocalModelsStore(service: LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine()))
    await fa.setPreloadShouldBlock(true)
    let t = Task { await store.preload(modelID: "parakeet-tdt-ctc-110m") }
    while store.loadingModelID == nil { await Task.yield() }
    #expect(store.loadingModelID == "parakeet-tdt-ctc-110m")
    #expect(store.residentModelID == nil)          // not resident until the load finishes
    await fa.releasePreloadGate()
    await t.value
    #expect(store.loadingModelID == nil)            // cleared when done
    #expect(store.residentModelID == "parakeet-tdt-ctc-110m")
}

@MainActor @Test func failedPreloadClearsLoadingModelID() async {
    let fa = FakeEngine()
    let store = LocalModelsStore(service: LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine()))
    await fa.setPreloadShouldThrow(true)
    await store.preload(modelID: "parakeet-tdt-ctc-110m")
    #expect(store.loadingModelID == nil)
    #expect(store.residentModelID == nil)
}

@MainActor @Test func slowUnloadShowsUnloadingModelIDAfterDelay() async {
    let fa = FakeEngine()
    let store = LocalModelsStore(
        service: LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine()),
        unloadSpinnerDelay: .zero)                  // fire the delayed spinner at once for the test
    await store.preload(modelID: "parakeet-tdt-ctc-110m")
    await fa.setUnloadShouldBlock(true)
    let t = Task { await store.preload(modelID: nil) }   // unload blocks inside the engine
    while store.unloadingModelID == nil { await Task.yield() }
    #expect(store.unloadingModelID == "parakeet-tdt-ctc-110m")
    await fa.releaseUnloadGate()
    await t.value
    #expect(store.unloadingModelID == nil)
    #expect(store.residentModelID == nil)
}

@MainActor @Test func fastUnloadNeverShowsUnloadingModelID() async {
    let fa = FakeEngine()
    let store = LocalModelsStore(
        service: LocalTranscriptionService(fluidAudio: fa, whisperKit: FakeEngine()),
        unloadSpinnerDelay: .seconds(30))           // long delay; a fast unload beats it
    await store.preload(modelID: "parakeet-tdt-ctc-110m")
    await store.preload(modelID: nil)               // unloads immediately, no block
    #expect(store.unloadingModelID == nil)
    #expect(store.residentModelID == nil)
}

@MainActor @Test func deletingResidentDictationModelClearsBadges() async {
    let store = LocalModelsStore(service: LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine()))
    let model = LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!
    await store.download(model)
    await store.preload(modelID: model.id)
    store.dictationModelID = model.id
    #expect(store.residentModelID == model.id)

    await store.delete(model)
    #expect(store.residentModelID == nil)          // in-memory badge cleared
    #expect(store.dictationModelID == nil)         // dictation badge cleared
    #expect(store.states[model.id]?.isDownloaded == false)
}

@MainActor @Test func deletingOtherModelKeepsDictationSelection() async {
    let store = LocalModelsStore(service: LocalTranscriptionService(fluidAudio: FakeEngine(), whisperKit: FakeEngine()))
    let dictation = LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")!
    let other = LocalModelCatalog.model(id: "whisper-large-v3-turbo")!
    store.dictationModelID = dictation.id
    await store.download(other)

    await store.delete(other)
    #expect(store.dictationModelID == dictation.id)   // unrelated selection untouched
}
