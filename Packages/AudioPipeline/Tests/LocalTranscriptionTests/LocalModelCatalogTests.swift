import Testing
@testable import LocalTranscription

@Test func catalogHasSixModelsWithUniqueIDs() {
    let all = LocalModelCatalog.all
    #expect(all.count == 6)
    #expect(Set(all.map(\.id)).count == 6)
}

@Test func recommendedModelIsParakeet110m() {
    let rec = LocalModelCatalog.all.filter(\.recommended)
    #expect(rec.count == 1)
    #expect(rec.first?.id == "parakeet-tdt-ctc-110m")
}

@Test func lookupResolvesWhisperTurboToWhisperKit() {
    let m = LocalModelCatalog.model(id: "whisper-large-v3-turbo")
    #expect(m?.runner == .whisperKit)
    #expect(m?.selector == "openai_whisper-large-v3-v20240930_626MB")
}

@Test func cohereIsFluidAudioCohereRunner() {
    #expect(LocalModelCatalog.model(id: "cohere-transcribe")?.runner == .fluidAudioCohere)
}
