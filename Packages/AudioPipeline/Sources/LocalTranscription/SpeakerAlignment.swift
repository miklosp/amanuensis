import Foundation

/// Assign each transcribed word to a diarized speaker by time, then merge
/// consecutive same-speaker words into runs. Words carry their own leading
/// spaces, so run text is a plain concatenation, trimmed per run. Each run also
/// carries `start` — the start time of its first word — so the renderer can
/// prefix a per-turn timestamp.
///
/// A word whose midpoint lands inside a diarizer segment ("strong") takes that
/// segment's speaker. A word that falls in a gap between segments ("weak") — the
/// diarizer never covered it — is attributed to the speaker of the temporally
/// nearest strong word, i.e. the nearest *actually transcribed* speech, rather
/// than the nearest segment. Diarizer segments are often padded with silence
/// around the real speech, so nearest-segment pulls a turn's edge words toward a
/// neighbour whose padding happens to sit closer; anchoring to real words keeps a
/// turn's trailing/leading words with the turn. Falls back to nearest segment
/// only when no word landed in any segment.
func attributeSpeakers(words: [TimedWord], segments: [DiarizedSegment]) -> [(speaker: String, text: String, start: Double)] {
    guard !segments.isEmpty else { return [] }

    // Pass 1: strong assignment — the segment containing the word's midpoint, or nil for a
    // gap word the diarizer never covered.
    let strong: [String?] = words.map { word in
        let mid = (word.start + word.end) / 2
        return segments.first { mid >= $0.start && mid <= $0.end }?.speakerId
    }

    // Pass 2: resolve every word. Strong words keep their speaker; gap words take the nearest
    // strong word's speaker, falling back to the nearest segment only when nothing landed strong.
    let speakers: [String] = words.indices.map { i in
        if let s = strong[i] { return s }
        let mid = (words[i].start + words[i].end) / 2
        return nearestStrongSpeaker(to: i, words: words, strong: strong)
            ?? nearestSegmentSpeaker(toMidpoint: mid, in: segments)
    }

    // Pass 3: merge consecutive same-speaker words into runs.
    var runs: [(speaker: String, text: String, start: Double)] = []
    for (i, word) in words.enumerated() {
        let speaker = speakers[i]
        if let last = runs.last, last.speaker == speaker {
            runs[runs.count - 1].text += word.text
        } else {
            runs.append((speaker: speaker, text: word.text, start: word.start))
        }
    }
    return runs.map { (speaker: $0.speaker, text: $0.text.trimmingCharacters(in: .whitespaces), start: $0.start) }
}

// The speaker of the strong-assigned word nearest word `i` by time gap. Words are
// time-ordered, so it scans outward for the first strong word on each side and, when
// both exist, takes the closer one — ties go to the preceding word so a turn's trailing
// word stays with the turn it ends. nil when no word has a strong assignment.
private func nearestStrongSpeaker(to i: Int, words: [TimedWord], strong: [String?]) -> String? {
    let mid = (words[i].start + words[i].end) / 2
    var left: Int?
    var k = i - 1
    while k >= 0 { if strong[k] != nil { left = k; break }; k -= 1 }
    var right: Int?
    k = i + 1
    while k < words.count { if strong[k] != nil { right = k; break }; k += 1 }
    switch (left, right) {
    case (nil, nil):    return nil
    case (let l?, nil): return strong[l]
    case (nil, let r?): return strong[r]
    case (let l?, let r?):
        return gap(mid, words[l]) <= gap(mid, words[r]) ? strong[l] : strong[r]
    }
}

// Distance from time `t` to a word's [start, end] interval (0 if inside).
private func gap(_ t: Double, _ w: TimedWord) -> Double {
    if t < w.start { return w.start - t }
    if t > w.end { return t - w.end }
    return 0
}

private func nearestSegmentSpeaker(toMidpoint mid: Double, in segments: [DiarizedSegment]) -> String {
    let nearest = segments.min { a, b in distance(mid, a) < distance(mid, b) }
    return nearest?.speakerId ?? ""
}

private func distance(_ t: Double, _ s: DiarizedSegment) -> Double {
    if t < s.start { return s.start - t }
    if t > s.end { return t - s.end }
    return 0
}
