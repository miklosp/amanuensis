import Testing
@testable import LocalTranscription

@Test func catalogHasSevenModelsWithUniqueIDs() {
    let all = LocalModelCatalog.all
    #expect(all.count == 7)
    #expect(Set(all.map(\.id)).count == 7)
}

@Test func indicConformerIsPresentWithSevenLanguages() {
    let m = LocalModelCatalog.model(id: "indic-conformer-600m")
    #expect(m?.runner == .indicConformer)
    #expect(m?.recommended == false)   // global recommended stays Parakeet 110m
    for language in ["Hindi", "Bengali", "Marathi", "Telugu", "Tamil", "Malayalam", "Kannada"] {
        #expect(m?.languages.contains(language) == true)
    }
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

@Test func defaultedSelectionPicksFirstWhenCurrentIsMissing() {
    #expect(LocalModelCatalog.defaultedSelection(current: "", downloaded: ["a", "b"]) == "a")
    #expect(LocalModelCatalog.defaultedSelection(current: "gone", downloaded: ["a", "b"]) == "a")
}

@Test func defaultedSelectionKeepsValidCurrent() {
    #expect(LocalModelCatalog.defaultedSelection(current: "b", downloaded: ["a", "b"]) == nil)
}

@Test func defaultedSelectionIsNilWhenNothingDownloaded() {
    #expect(LocalModelCatalog.defaultedSelection(current: "", downloaded: []) == nil)
}

@Test func defaultLanguageSnapsToModelFirstWhenUnsupported() {
    // IndicConformer lists Hindi first and doesn't support "en" → defaults to Hindi.
    #expect(LocalModelCatalog.defaultLanguage(forModel: "indic-conformer-600m", current: "en") == "hi")
    // A language the model already supports is kept (nil = no change).
    #expect(LocalModelCatalog.defaultLanguage(forModel: "indic-conformer-600m", current: "bn") == nil)
    #expect(LocalModelCatalog.defaultLanguage(forModel: "indic-conformer-600m", current: "hi") == nil)
    // Unknown / cloud model id → nil (left untouched).
    #expect(LocalModelCatalog.defaultLanguage(forModel: "gpt-4o-transcribe", current: "en") == nil)
}
