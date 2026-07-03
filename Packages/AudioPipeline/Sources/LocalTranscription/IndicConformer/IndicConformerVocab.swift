import Foundation

nonisolated struct IndicConformerVocab: Sendable {
    private let tokens: [IndicConformerLanguage: [String]]

    init(tokens: [IndicConformerLanguage: [String]]) { self.tokens = tokens }

    init(vocabURL: URL) throws {
        let raw = try JSONDecoder().decode([String: [String]].self, from: try Data(contentsOf: vocabURL))
        var parsed: [IndicConformerLanguage: [String]] = [:]
        for language in IndicConformerLanguage.allCases {
            guard let t = raw[language.rawValue], t.count > IndicConformerConfig.blankId else {
                throw LocalTranscriptionError.transcriptionFailed("IndicConformer vocab is missing \(language.rawValue) tokens.")
            }
            parsed[language] = t
        }
        self.tokens = parsed
    }

    func decode(_ ids: [Int], language: IndicConformerLanguage) -> String {
        guard let t = tokens[language] else { return "" }
        let pieces = ids.compactMap { id -> String? in
            guard id != IndicConformerConfig.blankId, id >= 0, id < t.count else { return nil }
            return t[id]
        }
        return pieces.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
