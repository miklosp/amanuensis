import SwiftUI

// The floating cue shown when another app starts using the mic. Two actions:
// start recording, or dismiss. Rendered inside MicCueController's NSPanel.
struct MicCueView: View {
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mic in use")
                    .font(.headline)
                Button("Start recording", action: onStart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
