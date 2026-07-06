import Testing
import AudioPipelineJobs   // plain import — these renderers are public

@Test func timestampedRunsPrefixEachTurnWithMmSs() {
    let out = formatSpeakerRunsWithTimestamps([
        (speaker: "A", text: "hello", start: 0.0),
        (speaker: "B", text: "hi there", start: 12.4),
        (speaker: "A", text: "again", start: 75.0),
    ])
    #expect(out == "[00:00] Speaker 1: hello\n[00:12] Speaker 2: hi there\n[01:15] Speaker 1: again")
}

@Test func timestampRollsToHoursPastOneHour() {
    let out = formatSpeakerRunsWithTimestamps([
        (speaker: 1, text: "late", start: 3661.0),   // 1h 01m 01s
    ])
    #expect(out == "[1:01:01] Speaker 1: late")
}

@Test func plainFormatSpeakerRunsUnchanged() {
    // The cloud-provider renderer must keep its original, timestamp-free output.
    let out = formatSpeakerRuns([(speaker: 1, text: "a"), (speaker: 2, text: "b")])
    #expect(out == "Speaker 1: a\nSpeaker 2: b")
}
