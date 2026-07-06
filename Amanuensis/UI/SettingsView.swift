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
                Toggle(isOn: $settings.keepSeparateTracks) {
                    VStack(alignment: .leading) {
                        Text("Keep separate mic & system tracks")
                        Text("Also save mic.flac and system.flac next to the combined recording. Needed for per-speaker attribution of group recordings.")
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
