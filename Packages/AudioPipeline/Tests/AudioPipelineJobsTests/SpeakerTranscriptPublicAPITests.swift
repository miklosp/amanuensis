import Testing
import AudioPipelineJobs   // NOT @testable — proves formatSpeakerRuns is public

@Test func formatSpeakerRunsIsPublic() {
    #expect(formatSpeakerRuns([(speaker: 1, text: "a"), (speaker: 2, text: "b")]) == "Speaker 1: a\nSpeaker 2: b")
}
