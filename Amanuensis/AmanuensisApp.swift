import AppSettings
#if DEBUG
import DictationCore
#endif
import SwiftUI

@main
struct AmanuensisApp: App {
    @NSApplicationDelegateAdaptor(AmanuensisAppDelegate.self) private var appDelegate
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(coordinator: coordinator)
        } label: {
            DictationMenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Window("Amanuensis", id: "main") {
            MainWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 880, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenMainWindowCommand()
            }
            #if DEBUG
            CommandMenu("Streaming Spike") {
                StreamingSpikeCommands(coordinator: coordinator)
            }
            #endif
        }

        Settings {
            SettingsView(settings: coordinator.settings, coordinator: coordinator)
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

#if DEBUG
private struct StreamingSpikeCommands: View {
    let coordinator: AppCoordinator

    var body: some View {
        Button("Revisable × Clipboard (k=2)") {
            launch(.revisableSample, ClipboardAppendInserter(), k: 2)
        }
        Button("Revisable × Keystroke (k=2)") {
            launch(.revisableSample, KeystrokeDiffInserter(), k: 2)
        }
        Button("Revisable × Clipboard (k=3)") {
            launch(.revisableSample, ClipboardAppendInserter(), k: 3)
        }
        Button("Immutable × Clipboard (k=2)") {
            launch(.immutableSample, ClipboardAppendInserter(), k: 2)
        }
        Button("Immutable × Keystroke (k=2)") {
            launch(.immutableSample, KeystrokeDiffInserter(), k: 2)
        }
        Divider()
        Button("Reson8 Realtime (Keystroke)") {
            launchReson8(KeystrokeDiffInserter(), k: 3)
        }
        Button("Reson8 Realtime (Clipboard k=3)") {
            launchReson8(ClipboardAppendInserter(), k: 3)
        }
    }

    private func launch(_ script: SimulatedTranscriptScript, _ strategy: InsertionStrategy, k: Int) {
        let harness = StreamingSpikeHarness(script: script, strategy: strategy, stabilityCount: k)
        Task { await harness.run() }   // harness retained by the task until run() completes
    }

    private func launchReson8(_ strategy: InsertionStrategy, k: Int) {
        let harness = Reson8SpikeHarness(
            providers: coordinator.providers, keychain: coordinator.keychain,
            strategy: strategy, stabilityCount: k, captureSeconds: 20)
        Task { await harness.run() }   // harness retained by the task until run() completes
    }
}
#endif
