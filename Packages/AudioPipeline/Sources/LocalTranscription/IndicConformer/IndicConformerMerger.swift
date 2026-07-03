import Foundation

nonisolated enum IndicConformerMerger {
    static func mergeTokens(_ chunks: [[Int]], maxOverlap: Int = 64) -> (tokenIds: [Int], appliedOverlap: Bool) {
        var merged: [Int] = []
        var appliedOverlap = false
        for chunk in chunks where !chunk.isEmpty {
            guard !merged.isEmpty else { merged.append(contentsOf: chunk); continue }
            let limit = min(maxOverlap, merged.count, chunk.count)
            var overlap = 0
            if limit > 0 {
                for count in stride(from: limit, through: 1, by: -1) where Array(merged.suffix(count)) == Array(chunk.prefix(count)) {
                    overlap = count; break
                }
            }
            if overlap > 0 { appliedOverlap = true }
            merged.append(contentsOf: chunk.dropFirst(overlap))
        }
        return (merged, appliedOverlap)
    }

    static func mergeTexts(_ transcripts: [String]) -> String {
        var mergedWords: [String] = []
        for transcript in transcripts {
            let words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            guard !mergedWords.isEmpty else { mergedWords.append(contentsOf: words); continue }
            let existing = mergedWords.map(normalize)
            let incoming = words.map(normalize)
            let maxOverlap = min(existing.count, incoming.count, 16)
            var overlap = 0
            if maxOverlap > 0 {
                for count in stride(from: maxOverlap, through: 1, by: -1) where Array(existing.suffix(count)) == Array(incoming.prefix(count)) {
                    overlap = count; break
                }
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return mergedWords.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        return String(String.UnicodeScalarView(token.unicodeScalars.filter { !punctuation.contains($0) })).lowercased()
    }
}
