import AppSettings
import AudioPipelineJobs
import RecordingStorage
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
            SettingsView(settings: coordinator.settings,
                         presets: coordinator.presets,
                         jobs: coordinator.jobs,
                         keychain: coordinator.keychain)
        }

        Window("Recordings", id: "recordings") {
            RecordingsView(library: coordinator.library, coordinator: coordinator)
        }
    }
}
