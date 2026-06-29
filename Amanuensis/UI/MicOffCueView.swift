import SwiftUI

// The floating cue shown when the app that was using the mic (a meeting)
// releases it while we are recording, offering to stop recording. A thin
// CueCard wrapper — see CueCard for the styling. Rendered inside
// FloatingCueController's NSPanel.
struct MicOffCueView: View {
    let onStop: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        CueCard(
            systemImage: "stop.fill",
            title: "Meeting ended",
            subtitle: "Stop recording",
            onAction: onStop,
            onDismiss: onDismiss
        )
    }
}
