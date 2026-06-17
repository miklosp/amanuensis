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

            Button("Open Amanuensis") {
                // Flip activation policy first so NSApp.activate() actually
                // brings the window to the front — .activate is a no-op
                // when the app is .accessory.
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate()
                DispatchQueue.main.async {
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
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
