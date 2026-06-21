import DictationCore
import SwiftUI

/// State-driven menu-bar icon: idle, meeting-recording, or dictating (animated).
struct DictationMenuBarLabel: View {
    let coordinator: AppCoordinator

    var body: some View {
        if coordinator.dictation.phase != .idle {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        } else if coordinator.isRecording {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.hierarchical)
        } else {
            Image(systemName: "waveform.circle")
                .symbolRenderingMode(.hierarchical)
        }
    }
}
