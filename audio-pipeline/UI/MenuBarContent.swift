import SwiftUI

struct MenuBarContent: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Group {
            statusLine

            Divider()

            Button(coordinator.isRecording ? "Stop recording" : "Start recording") {
                coordinator.toggleRecording()
            }
            .keyboardShortcut("r")
            .disabled(coordinator.isBusy)

            Divider()

            Button("Open last recording folder") {
                coordinator.openLastRecordingFolder()
            }
            .disabled(coordinator.lastFolderURL == nil)

            Button("Open recordings folder") {
                coordinator.openRecordingsFolder()
            }

            if let error = coordinator.lastError {
                Divider()
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch coordinator.status {
        case .idle:
            Text("Idle")
        case .starting:
            Text("Starting…")
        case .recording(let name):
            Text("Recording: \(name)")
        case .stopping:
            Text("Stopping…")
        }
    }
}
