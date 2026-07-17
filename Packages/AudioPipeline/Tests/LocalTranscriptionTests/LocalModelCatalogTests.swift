import Testing
@testable import LocalTranscription

@Test func catalogHasEightModelsWithUniqueIDs() {
    let all = LocalModelCatalog.all
    #expect(all.count == 8)
    #expect(Set(all.map(\.id)).count == 8)
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

@Test func resolvedLanguageNormalizesPersistedValueForDispatch() {
    // A supported explicit choice is kept as-is (incl. "en" on SenseVoice).
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "indic-conformer-600m", requested: "bn") == "bn")
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "sensevoice-small", requested: "en") == "en")
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "parakeet-tdt-v3", requested: "fr") == "fr")
    // Blank/nil/unsupported on a dedicated model resolves to its declared default —
    // this is what stops a persisted IndicConformer entry from hard-failing the guard.
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "indic-conformer-600m", requested: nil) == "hi")
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "indic-conformer-600m", requested: "") == "hi")
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "indic-conformer-600m", requested: "en") == "hi")
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "parakeet-tdt-ja", requested: "en") == "ja")
    // A stale code on an auto-detect model drops to nil (auto-detect) rather than
    // being forwarded — the regression this PR review flagged for Cohere/parakeet-v3.
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "parakeet-tdt-v3", requested: "ta") == nil)
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "cohere-transcribe", requested: "hi") == nil)
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "whisper-large-v3-turbo", requested: "") == nil)
    // Unknown/cloud ids pass the requested value straight through untouched.
    #expect(LocalModelCatalog.resolvedLanguage(forModel: "gpt-4o-transcribe", requested: "en") == "en")
}

@Test func pickerLanguageSnapsOutOfRangeToDefaultOrAuto() {
    // Same rule as resolvedLanguage, but auto-detect surfaces as "" (a valid Picker
    // tag) so the control never holds an out-of-range selection after a model switch.
    #expect(LocalModelCatalog.pickerLanguage(forModel: "parakeet-tdt-v3", current: "ta") == "")
    #expect(LocalModelCatalog.pickerLanguage(forModel: "cohere-transcribe", current: "hi") == "")
    #expect(LocalModelCatalog.pickerLanguage(forModel: "indic-conformer-600m", current: "en") == "hi")
    #expect(LocalModelCatalog.pickerLanguage(forModel: "parakeet-tdt-v3", current: "fr") == "fr")
}
