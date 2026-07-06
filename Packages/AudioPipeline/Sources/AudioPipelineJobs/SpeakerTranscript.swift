// Renders speaker-tagged runs as "Speaker N: text" lines, numbering speakers in
// first-seen order. Shared by the diarizing transcript handlers (Reson8, Soniox,
// ElevenLabs, Deepgram): each builds its own runs — grouping, token spacing,
// orphan-word handling and the no-speaker fallback all differ per provider — and
// hands the finalized per-run text here for the common numbering and formatting.
// Generic over the speaker key (Int for most providers, String for ElevenLabs).
public func formatSpeakerRuns<Speaker: Hashable>(_ runs: [(speaker: Speaker, text: String)]) -> String {
    var numbering = SpeakerNumbering<Speaker>()
    let lines = runs.map { "Speaker \(numbering.number(for: $0.speaker)): \($0.text)" }
    return lines.joined(separator: "\n")
}

/// Like `formatSpeakerRuns`, but prefixes each turn with its start time as
/// `[mm:ss]` (or `[h:mm:ss]` past an hour): `[00:12] Speaker 1: …`. Used by the
/// local diarizing path, whose runs carry a per-turn `start` in seconds.
public func formatSpeakerRunsWithTimestamps<Speaker: Hashable>(
    _ runs: [(speaker: Speaker, text: String, start: Double)]
) -> String {
    var numbering = SpeakerNumbering<Speaker>()
    let lines = runs.map { run in
        "[\(timestampLabel(run.start))] Speaker \(numbering.number(for: run.speaker)): \(run.text)"
    }
    return lines.joined(separator: "\n")
}

// Assigns 1-based speaker numbers in first-seen order. Shared by both renderers.
private struct SpeakerNumbering<Speaker: Hashable> {
    private var order: [Speaker: Int] = [:]
    private var next = 1
    mutating func number(for speaker: Speaker) -> Int {
        if let existing = order[speaker] { return existing }
        defer { next += 1 }
        order[speaker] = next
        return next
    }
}

// Seconds → "mm:ss", rolling to "h:mm:ss" once past an hour. Negative clamped to 0.
private func timestampLabel(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
