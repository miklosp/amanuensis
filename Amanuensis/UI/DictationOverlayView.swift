import SwiftUI
import DictationCore

struct DictationOverlayView: View {
    let phase: DictationStateMachine.Phase
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .listening:
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Listening…")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing…")
            case .inserting, .idle:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Inserted")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
