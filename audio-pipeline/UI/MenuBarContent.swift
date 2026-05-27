import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

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

            Button("Recordings…") {
                openWindow(id: "recordings")
                NSApp.activate()
                // Raise the recordings window above other windows of this app.
                // Defer one runloop tick so openWindow has time to surface the window.
                DispatchQueue.main.async {
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "recordings" }) {
                        win.makeKeyAndOrderFront(nil)
                    }
                }
            }

            if let error = coordinator.lastError {
                Divider()
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }

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
