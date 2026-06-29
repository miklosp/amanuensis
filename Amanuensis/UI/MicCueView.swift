import SwiftUI

// The floating cue shown when another app starts using the mic (a likely
// meeting), offering to start recording. A thin CueCard wrapper — see CueCard
// for the styling. Rendered inside FloatingCueController's NSPanel.
struct MicCueView: View {
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CueCard(
            systemImage: "mic.fill",
            title: "Mic in use",
            subtitle: "Start recording",
            onAction: onStart,
            onDismiss: onDismiss
        )
    }
}
