import Foundation

/// Assign each transcribed word to a diarized speaker by time, then merge
/// consecutive same-speaker words into runs. WhisperKit words carry their own
/// leading spaces, so run text is a plain concatenation, trimmed per run. Each
/// run also carries `start` — the start time of its first word — so the renderer
/// can prefix a per-turn timestamp.
func attributeSpeakers(words: [TimedWord], segments: [DiarizedSegment]) -> [(speaker: String, text: String, start: Double)] {
    guard !segments.isEmpty else { return [] }
    var runs: [(speaker: String, text: String, start: Double)] = []
    for word in words {
        let mid = (word.start + word.end) / 2
        let speaker = speakerId(forMidpoint: mid, in: segments)
        if let last = runs.last, last.speaker == speaker {
            runs[runs.count - 1].text += word.text
        } else {
            runs.append((speaker: speaker, text: word.text, start: word.start))
        }
    }
    return runs.map { (speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start) }
}

private func speakerId(forMidpoint mid: Double, in segments: [DiarizedSegment]) -> String {
    if let hit = segments.first(where: { mid >= $0.start && mid <= $0.end }) { return hit.speakerId }
    // Nearest by distance to the [start, end] interval.
    let nearest = segments.min { a, b in distance(mid, a) < distance(mid, b) }
    return nearest?.speakerId ?? ""
}

private func distance(_ t: Double, _ s: DiarizedSegment) -> Double {
    if t < s.start { return s.start - t }
    if t > s.end { return t - s.end }
    return 0
}
