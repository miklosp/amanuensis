import AppSettings
import SwiftUI

@main
struct AudioPipelineApp: App {
    @NSApplicationDelegateAdaptor(AudioPipelineAppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.isRecording
                  ? "record.circle.fill"
                  : "waveform.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)

        Window("Audio Pipeline", id: "main") {
            MainWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 880, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenMainWindowCommand()
            }
        }

        Settings {
            SettingsView(settings: coordinator.settings)
        }
    }
}

private struct OpenMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "main")
        }
        .keyboardShortcut("n")
    }
}
