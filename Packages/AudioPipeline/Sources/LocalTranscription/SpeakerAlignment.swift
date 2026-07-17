import Foundation

/// Assign each transcribed word to a diarized speaker by time, then merge
/// consecutive same-speaker words into runs. Word boundary whitespace isn't a
/// fixed leading- or trailing-space convention across engines (Apple's
/// `TimedWord`s carry trailing spaces), so run text is a plain concatenation
/// that relies on each run being trimmed per run rather than on where the
/// space lives. Each run also carries `start` — the start time of its first
/// word — so the renderer can prefix a per-turn timestamp.
///
/// A word whose midpoint lands inside a diarizer segment ("strong") takes that
/// segment's speaker. A word that falls in a gap between segments ("weak") — the
/// diarizer never covered it — is attributed to the speaker of the temporally
/// nearest strong word, i.e. the nearest *actually transcribed* speech, rather
/// than the nearest segment. Diarizer segments are often padded with silence
/// around the real speech, so nearest-segment pulls a turn's edge words toward a
/// neighbour whose padding happens to sit closer; anchoring to real words keeps a
/// turn's trailing/leading words with the turn.
///
/// The exception is a gap word whose nearest segment belongs to a speaker with no
/// strong word anywhere — a short turn whose only word missed its own padded
/// segment. That speaker has no real-word anchor to pull toward, so the nearest
/// strong word necessarily belongs to a *different* speaker; honouring it would
/// swallow the whole short turn. In that case the segment is the only anchor we
/// have, so the word stays with the nearest segment. Falls back to nearest segment
/// too when no word landed in any segment at all.
func attributeSpeakers(words: [TimedWord], segments: [DiarizedSegment]) -> [(speaker: String, text: String, start: Double)] {
    guard !segments.isEmpty else { return [] }

    // Pass 1: strong assignment — the segment containing the word's midpoint, or nil for a
    // gap word the diarizer never covered.
    let strong: [String?] = words.map { word in
        let mid = (word.start + word.end) / 2
        return segments.first { mid >= $0.start && mid <= $0.end }?.speakerId
    }

    // Speakers that actually own transcribed speech. A gap word only anchors to the nearest
    // strong word when the nearest segment's speaker is in this set — otherwise that speaker has
    // no real word to anchor to and the strong word would belong to someone else (see doc comment).
    let anchoredSpeakers = Set(strong.compactMap { $0 })

    // Pass 2: resolve every word. Strong words keep their speaker; a gap word takes the nearest
    // strong word's speaker when its nearest segment's speaker is anchored, otherwise it stays
    // with that nearest (unanchored, real-word-less) segment.
    let speakers: [String] = words.indices.map { i in
        if let s = strong[i] { return s }
        let mid = (words[i].start + words[i].end) / 2
        let nearestSegment = nearestSegmentSpeaker(toMidpoint: mid, in: segments)
        guard anchoredSpeakers.contains(nearestSegment) else { return nearestSegment }
        return nearestStrongSpeaker(to: i, words: words, strong: strong) ?? nearestSegment
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
