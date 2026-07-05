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
    #expect(runs[1].speaker == "S2")
    #expect(runs[1].text == "hi")
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
