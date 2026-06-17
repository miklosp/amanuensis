import Foundation

// Pure formatters lifted out of `RecordingsView` so they're testable without
// instantiating a SwiftUI view.
enum RecordingFormatters {
    static func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
