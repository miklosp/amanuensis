import Foundation

nonisolated enum IndicConformerMerger {
    /// Concatenates independently-decoded chunk token streams, removing the
    /// duplicated overlap region between consecutive chunks.
    ///
    /// Chunks overlap by a fixed audio window, but the two decodes of that window
    /// can diverge on *either* side of the join, so a plain `suffix == prefix`
    /// match finds no overlap and duplicates the shared words:
    ///   - the earlier chunk truncates/varies its trailing word for lack of
    ///     right-context (e.g. "ಮುಗಿಸಿ" vs the later chunk's full "ಮುಗಿಸಿತು"), and
    ///   - the later chunk can hallucinate a leading token before re-decoding the
    ///     shared words (e.g. "ടിവാസനയാണ്" vs the earlier "വാസനയാണ്").
    ///
    /// So we search a small window on both sides: drop up to `maxSkip` trailing
    /// tokens of the accumulated output and skip up to `maxSkip` leading tokens of
    /// the incoming chunk, then take the longest exact run, preferring the least
    /// trimming. Clean boundaries still match at drop=0/lead=0, so they are
    /// unaffected.
    static func mergeTokens(_ chunks: [[Int]], maxOverlap: Int = 64, maxSkip: Int = 8) -> [Int] {
        var merged: [Int] = []
        for chunk in chunks where !chunk.isEmpty {
            guard !merged.isEmpty else { merged.append(contentsOf: chunk); continue }
            var best = (overlap: 0, drop: 0, lead: 0)
            let dropLimit = min(maxSkip, merged.count - 1)
            let leadLimit = min(maxSkip, chunk.count - 1)
            for drop in 0...dropLimit {
                let tail = merged.dropLast(drop)
                for lead in 0...leadLimit {
                    let head = chunk.dropFirst(lead)
                    let limit = min(maxOverlap, tail.count, head.count)
                    for count in stride(from: limit, through: 1, by: -1)
                    where Array(tail.suffix(count)) == Array(head.prefix(count)) {
                        if count > best.overlap { best = (count, drop, lead) }
                        break   // longest overlap for this (drop, lead)
                    }
                }
            }
            if best.overlap > 0 {
                merged.removeLast(best.drop)
                merged.append(contentsOf: chunk.dropFirst(best.lead + best.overlap))
            } else {
                merged.append(contentsOf: chunk)
            }
        }
        return merged
    }
}
