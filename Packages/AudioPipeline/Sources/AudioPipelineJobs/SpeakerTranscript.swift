// Renders speaker-tagged runs as "Speaker N: text" lines, numbering speakers in
// first-seen order. Shared by the diarizing transcript handlers (Reson8, Soniox,
// ElevenLabs, Deepgram): each builds its own runs — grouping, token spacing,
// orphan-word handling and the no-speaker fallback all differ per provider — and
// hands the finalized per-run text here for the common numbering and formatting.
// Generic over the speaker key (Int for most providers, String for ElevenLabs).
func formatSpeakerRuns<Speaker: Hashable>(_ runs: [(speaker: Speaker, text: String)]) -> String {
    var order: [Speaker: Int] = [:]
    var next = 1
    let lines = runs.map { run -> String in
        let n: Int
        if let existing = order[run.speaker] {
            n = existing
        } else {
            n = next
            order[run.speaker] = next
            next += 1
        }
        return "Speaker \(n): \(run.text)"
    }
    return lines.joined(separator: "\n")
}
