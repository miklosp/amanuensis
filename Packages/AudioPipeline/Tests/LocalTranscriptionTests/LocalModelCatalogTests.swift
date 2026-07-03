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

@Test func dedicatedModelsDeclareADefaultLanguage() {
    // The models the user cares about declare their primary language; broad
    // auto-detect models declare none.
    #expect(LocalModelCatalog.model(id: "indic-conformer-600m")?.defaultLanguage == "hi")
    #expect(LocalModelCatalog.model(id: "parakeet-tdt-ja")?.defaultLanguage == "ja")
    #expect(LocalModelCatalog.model(id: "sensevoice-small")?.defaultLanguage == "zh")
    #expect(LocalModelCatalog.model(id: "whisper-large-v3-turbo")?.defaultLanguage == nil)
    #expect(LocalModelCatalog.model(id: "parakeet-tdt-v3")?.defaultLanguage == nil)
}

@Test func defaultLanguageFixesOnlyUnsupportedCurrent() {
    // Snap to the declared default only when the current language isn't supported
    // (blank or a code outside the model's set) — otherwise keep the current one.
    #expect(LocalModelCatalog.defaultLanguage(forModel: "indic-conformer-600m", current: "en") == "hi")
    #expect(LocalModelCatalog.defaultLanguage(forModel: "indic-conformer-600m", current: "") == "hi")
    #expect(LocalModelCatalog.defaultLanguage(forModel: "parakeet-tdt-ja", current: "en") == "ja")
    // Already-supported languages are preserved (nil = no change) — incl. "en" on
    // SenseVoice, which supports it. Selecting the model still applies "zh" via the
    // model-change override; this fix-invalid path only guards against bad values.
    #expect(LocalModelCatalog.defaultLanguage(forModel: "sensevoice-small", current: "en") == nil)
    #expect(LocalModelCatalog.defaultLanguage(forModel: "indic-conformer-600m", current: "bn") == nil)
    // Auto-detect models declare no default → never forced. Unknown/cloud → nil.
    #expect(LocalModelCatalog.defaultLanguage(forModel: "whisper-large-v3-turbo", current: "") == nil)
    #expect(LocalModelCatalog.defaultLanguage(forModel: "gpt-4o-transcribe", current: "en") == nil)
}
