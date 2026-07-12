import Foundation
import FluidAudio

/// Collapse Parakeet's SentencePiece sub-word `TokenTiming`s into word-level `TimedWord`s.
///
/// Parakeet (TDT) emits sub-word tokens (e.g. `▁hel`, `lo`). A token whose text starts with the
/// SentencePiece boundary marker `▁` (U+2581) or an ASCII space begins a new word; other tokens
/// continue the current word. The first non-special token also begins a word. Each emitted word
/// carries a single leading space to match WhisperKit's convention, so the pipeline's
/// `words.map(\.text).joined()` reconstructs the transcript with correct inter-word spacing
/// (the leading space on word 1 is trimmed downstream).
///
/// Returns an empty array when `timings` is empty or holds only special tokens — the caller
/// treats that as "no timestamps available" and degrades to a plain transcript.
func groupParakeetWords(_ timings: [TokenTiming]) -> [TimedWord] {
    var words: [TimedWord] = []
    var current = ""
    var start = 0.0
    var end = 0.0
    var open = false   // whether `current` holds an in-progress word

    func flush() {
        guard open else { return }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            words.append(TimedWord(text: " " + trimmed, start: start, end: end))
        }
        current = ""
        open = false
    }

    for timing in timings {
        let token = timing.token
        if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
        let startsWord = token.hasPrefix("▁") || token.hasPrefix(" ")
        if startsWord || !open {
            flush()
            current = stripWordBoundary(token)
            start = timing.startTime
            open = true
        } else {
            current += token
        }
        end = timing.endTime
    }
    flush()
    return words
}

private func stripWordBoundary(_ token: String) -> String {
    if token.hasPrefix("▁") { return String(token.dropFirst()) }
    return String(token.drop(while: { $0 == " " }))
}
