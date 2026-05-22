import SwiftUI

@main
struct AudioPipelineApp: App {
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

        Settings {
            SettingsView(settings: coordinator.settings)
        }

        Window("Recordings", id: "recordings") {
            RecordingsView(library: coordinator.library)
        }
    }
}
