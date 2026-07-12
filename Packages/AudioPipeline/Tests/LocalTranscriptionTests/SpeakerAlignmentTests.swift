import Testing
@testable import LocalTranscription

private func w(_ t: String, _ s: Double, _ e: Double) -> TimedWord { TimedWord(text: t, start: s, end: e) }
private func seg(_ id: String, _ s: Double, _ e: Double) -> DiarizedSegment { DiarizedSegment(speakerId: id, start: s, end: e) }

@Test func groupsConsecutiveWordsBySpeaker() {
    let words = [w(" Hello", 0.0, 0.5), w(" there", 0.5, 1.0), w(" hi", 2.0, 2.5)]
    let segs  = [seg("S1", 0.0, 1.5), seg("S2", 1.5, 3.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.count == 2)
    #expect(runs[0].speaker == "S1")
    #expect(runs[0].text == "Hello there")
    #expect(runs[0].start == 0.0)   // start time of the run's first word
    #expect(runs[1].speaker == "S2")
    #expect(runs[1].text == "hi")
    #expect(runs[1].start == 2.0)
}

@Test func wordInGapUsesNearestSegment() {
    let words = [w(" x", 5.0, 5.2)]                 // midpoint 5.1, inside no segment
    let segs  = [seg("S1", 0.0, 1.0), seg("S2", 6.0, 7.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.count == 1)
    #expect(runs[0].speaker == "S2")               // nearest is S2 (0.9 away vs 4.1)
}

@Test func singleSpeakerProducesOneRun() {
    let words = [w(" a", 0.0, 0.5), w(" b", 0.5, 1.0)]
    let segs  = [seg("S1", 0.0, 2.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.count == 1)
    #expect(runs[0].text == "a b")
}

@Test func emptySegmentsYieldEmpty() {
    #expect(attributeSpeakers(words: [w(" a", 0, 1)], segments: []).isEmpty)
}

@Test func gapWordFollowsNearestTranscribedWordNotPaddedSegment() {
    // S2's segment is padded: it starts at 4.0 but its first real word ("c") is at 6.0.
    // "edge" (mid 3.7) is a gap word closer to the S2 *segment* (0.3) than to the S1
    // segment (0.7) — nearest-segment leaked it to S2 — but its nearest real word is
    // S1's "b" (gap 0.7) vs S2's "c" (gap 2.3), so it now stays with S1.
    let words = [w(" a", 1.0, 2.0), w(" b", 2.5, 3.0), w(" edge", 3.5, 3.9), w(" c", 6.0, 6.5)]
    let segs  = [seg("S1", 0.0, 3.0), seg("S2", 4.0, 12.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.map(\.speaker) == ["S1", "S2"])
    #expect(runs[0].text == "a b edge")
    #expect(runs[1].text == "c")
}

@Test func gapWordGoesToNextSpeakerWhenItIsTheNearestRealWord() {
    // "near" (mid 3.9) is a gap word whose nearest real word is S2's "b" (gap 0.2),
    // not S1's "a" (gap 2.9). The fix follows actual speech — it does not blindly keep
    // gap words with the preceding speaker.
    let words = [w(" a", 0.5, 1.0), w(" near", 3.8, 4.0), w(" b", 4.1, 4.6)]
    let segs  = [seg("S1", 0.0, 3.0), seg("S2", 4.05, 12.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.map(\.speaker) == ["S1", "S2"])
    #expect(runs[0].text == "a")
    #expect(runs[1].text == "near b")
}

@Test func gapWordNearestUnanchoredSegmentStaysWithThatSegment() {
    // S2 is a short turn (5.0–5.4) whose only word "b" (mid 4.9) missed its own padded
    // segment, so S2 has no strong-word anchor. "b" is a gap word 0.1 from the S2 segment
    // but 4.3 from S1's only strong word "a". Anchoring to the nearest strong word would
    // pull the whole S2 turn into S1; because S2's own segment is far nearer and S2 has no
    // strong word to anchor to, "b" must stay with S2.
    let words = [w(" a", 0.4, 0.6), w(" b", 4.8, 5.0)]
    let segs  = [seg("S1", 0.0, 1.0), seg("S2", 5.0, 5.4)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.map(\.speaker) == ["S1", "S2"])
    #expect(runs[0].text == "a")
    #expect(runs[1].text == "b")
}

@Test func equidistantGapWordPrefersPrecedingSpeaker() {
    // "mid" (mid 3.0) is equidistant between S1's "a" (gap 1.0) and S2's "b" (gap 1.0);
    // the tie goes to the preceding speaker, so a turn's trailing word stays with the
    // turn it ends.
    let words = [w(" a", 1.0, 2.0), w(" mid", 2.9, 3.1), w(" b", 4.0, 5.0)]
    let segs  = [seg("S1", 0.0, 2.5), seg("S2", 3.5, 12.0)]
    let runs = attributeSpeakers(words: words, segments: segs)
    #expect(runs.map(\.speaker) == ["S1", "S2"])
    #expect(runs[0].text == "a mid")
    #expect(runs[1].text == "b")
}
