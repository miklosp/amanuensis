import AppKit
import AppSettings
import RecordingCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let coordinator: AppCoordinator

    @State private var micGranted = MicrophonePermission.isAuthorized()
    @State private var systemAudioGranted = AudioCapturePermission.isAuthorized()
    @State private var inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
    @State private var postEventGranted = TextInserter.hasPostEventAccess()

    var body: some View {
        Form {
            Section("Mac privileges") {
                permissionRow(title: "Microphone", granted: micGranted) {
                    Task {
                        let ok = await MicrophonePermission.requestIfNeeded()
                        if !ok { openPrivacy("Privacy_Microphone") }
                        refreshPermissions()
                    }
                }
                permissionRow(title: "System Audio", granted: systemAudioGranted) {
                    Task {
                        let ok = await AudioCapturePermission.requestIfNeeded()
                        if !ok { openPrivacy("Privacy_ScreenCapture") }
                        refreshPermissions()
                    }
                }
                permissionRow(title: "Input Monitoring (hotkey)", granted: inputMonitoringGranted) {
                    HotkeyTapMonitor.requestInputMonitoringAccess()
                    refreshPermissions()
                }
                permissionRow(title: "Accessibility · post events (auto-insert)", granted: postEventGranted) {
                    TextInserter.requestPostEventAccess()
                    refreshPermissions()
                }
            }
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
                Toggle(isOn: $settings.suggestStoppingWhenMeetingEnds) {
                    VStack(alignment: .leading) {
                        Text("Offer to stop recording when the meeting ends")
                        Text("While recording, when the app that was using the microphone releases it, Amanuensis shows a cue to stop recording. Watches running processes other than itself.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: settings.suggestStoppingWhenMeetingEnds) { _, newValue in
                    coordinator.setMicOffCueEnabled(newValue)
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

                Toggle("Stream results live", isOn: $settings.dictation.streamLive)
                    .disabled(!selectedProviderStreams)
                    .onChange(of: settings.dictation.streamLive) { _, _ in
                        coordinator.dictation.settingsChanged()
                    }
                if settings.dictation.streamLive && selectedProviderStreams {
                    Picker("Language", selection: $settings.dictation.language) {
                        ForEach(dictationLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                } else if !selectedProviderStreams {
                    Text("The selected provider doesn't support live streaming.")
                        .font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 480, height: 560)
        .onAppear { refreshPermissions() }
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

    private var selectedProviderStreams: Bool {
        guard let pid = settings.dictation.providerID,
              let provider = coordinator.allProviders.first(where: { $0.id == pid })
        else { return false }
        return RealtimeProviderRegistry.provider(for: provider.presetID) != nil
    }

    private var holdThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settings.dictation.holdThresholdMs) },
            set: { settings.dictation.holdThresholdMs = Int($0) })
    }

    private func refreshPermissions() {
        micGranted = MicrophonePermission.isAuthorized()
        systemAudioGranted = AudioCapturePermission.isAuthorized()
        inputMonitoringGranted = HotkeyTapMonitor.hasInputMonitoringAccess()
        postEventGranted = TextInserter.hasPostEventAccess()
    }

    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
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

// Curated BCP-47 list for streaming dictation. Providers map/validate their own
// supported codes; this is a shared starter set, extendable later.
private let dictationLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
    ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
]
