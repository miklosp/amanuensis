import Testing
@testable import LocalTranscription

@Suite struct LocalModelLanguagesTests {
    @Test func everyModelHasNonEmptyWellFormedCodes() {
        for model in LocalModelCatalog.all {
            #expect(!model.supportedLanguages.isEmpty, "\(model.id) has no languages")
            for code in model.supportedLanguages {
                #expect(code == code.lowercased(), "\(model.id): \(code) not lowercase")
                #expect(
                    code.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
                    "\(model.id): \(code) is not a 2–3 char code")
            }
            #expect(
                Set(model.supportedLanguages).count == model.supportedLanguages.count,
                "\(model.id) has duplicate codes")
        }
    }

    // For catalog entries whose `languages` summary begins with an integer
    // ("99 languages", "25 European languages", "14 languages (…)"), that
    // number must equal the code count. "50+ (…)" and word summaries
    // ("English", "Japanese", "Multilingual…") have no leading "<n> " and are
    // skipped — this catches summary/list drift without asserting linguistics.
    @Test func summaryCountMatchesListWhenSummaryLeadsWithNumber() {
        for model in LocalModelCatalog.all {
            guard let r = model.languages.range(of: "^\\d+ ", options: .regularExpression)
            else { continue }
            let n = Int(model.languages[r].trimmingCharacters(in: .whitespaces))!
            #expect(
                model.supportedLanguages.count == n,
                "\(model.id): summary says \(n), list has \(model.supportedLanguages.count)")
        }
    }

    @Test func fixedCountsAreExact() {
        #expect(LocalModelCatalog.model(id: "cohere-transcribe")?.supportedLanguages.count == 14)
        #expect(LocalModelCatalog.model(id: "whisper-large-v3-turbo")?.supportedLanguages.count == 99)
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-v3")?.supportedLanguages.count == 25)
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-ctc-110m")?.supportedLanguages == ["en"])
        #expect(LocalModelCatalog.model(id: "parakeet-tdt-ja")?.supportedLanguages == ["ja"])
    }
}
