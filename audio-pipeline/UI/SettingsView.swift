import AppKit
import AppSettings
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(settings.recordingsDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseLocation)
                    }
                }
            }
            Section("After recording stops") {
                Toggle(isOn: $settings.keepOriginalCAF) {
                    VStack(alignment: .leading) {
                        Text("Keep original .caf recordings")
                        Text("Combined .flac is always produced. Disable this to delete the raw mic/system .caf files after combining.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingsDirectory = url
        }
    }
}
