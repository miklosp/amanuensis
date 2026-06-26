import AppKit
import AppSettings
import AudioPipelineJobs
import DictationCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator

    @State private var inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
    @State private var postEventGranted = TextInserter.hasPostEventAccess()

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
            Section("Meetings") {
                Toggle(isOn: $settings.suggestRecordingWhenMicInUse) {
                    VStack(alignment: .leading) {
                        Text("Offer to record when the mic is in use")
                        Text("When another app starts using the microphone (e.g. a meeting), Amanuensis shows a cue to start recording. Watches the default input device only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.suggestRecordingWhenMicInUse) { _, newValue in
                    coordinator.setMicCueEnabled(newValue)
                }
            }
            Section("Dictation") {
                Toggle("Enable dictation", isOn: $settings.dictation.enabled)
                    .onChange(of: settings.dictation.enabled) { _, _ in
                        coordinator.dictation.settingsChanged()
                    }

                Picker("Trigger key", selection: $settings.dictation.trigger) {
                    ForEach(TriggerModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .onChange(of: settings.dictation.trigger) { _, _ in
                    coordinator.dictation.settingsChanged()
                }
                if settings.dictation.trigger == .function {
                    Text("Fn may also trigger a macOS action (System Settings ▸ Keyboard ▸ “Press 🌐 to”).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Hold threshold") {
                    HStack {
                        Slider(value: holdThresholdBinding, in: 150...600, step: 50)
                        Text("\(settings.dictation.holdThresholdMs) ms")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                Picker("Provider", selection: $settings.dictation.providerID) {
                    Text("None").tag(UUID?.none)
                    ForEach(coordinator.allProviders) { provider in
                        Text(provider.name).tag(UUID?.some(provider.id))
                    }
                }

                TextField("Model", text: $settings.dictation.model)

                Picker("On finish", selection: $settings.dictation.insertMode) {
                    Text("Insert at cursor").tag(InsertMode.autoInsert)
                    Text("Copy to clipboard").tag(InsertMode.clipboardOnly)
                }

                Toggle("Show overlay while dictating", isOn: $settings.dictation.showOverlay)

                permissionRow(
                    title: "Input Monitoring (hotkey)",
                    granted: inputMonitoringGranted,
                    grant: {
                        HotkeyTapMonitor.requestInputMonitoringAccess()
                        refreshPermissions()
                    })
                permissionRow(
                    title: "Accessibility · post events (auto-insert)",
                    granted: postEventGranted,
                    grant: {
                        TextInserter.requestPostEventAccess()
                        refreshPermissions()
                    })
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.recordingsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.selectRecordingsFolder(url)
        }
    }

    private var holdThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.dictation.holdThresholdMs) },
            set: { settings.dictation.holdThresholdMs = Int($0) })
    }

    private func refreshPermissions() {
        inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
        postEventGranted = TextInserter.hasPostEventAccess()
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button("Grant…", action: grant)
            }
        }
    }
}
