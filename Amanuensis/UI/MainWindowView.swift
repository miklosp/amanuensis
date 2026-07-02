import SwiftUI

struct MainWindowView: View {
    let coordinator: AppCoordinator

    @State private var selection: SidebarDestination = .recordings
    @State private var lifecycleDelegate = MainWindowLifecycleDelegate()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("Recordings", systemImage: "waveform")
                        .tag(SidebarDestination.recordings)
                    Label("Jobs", systemImage: "wand.and.stars")
                        .tag(SidebarDestination.jobs)
                    Label("Providers", systemImage: "key")
                        .tag(SidebarDestination.providers)
                    Label("Local Models", systemImage: "cpu")
                        .tag(SidebarDestination.localModels)
                    Label("Logs", systemImage: "list.bullet.rectangle")
                        .tag(SidebarDestination.logs)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarActivityBar(coordinator: coordinator)
            }
        } detail: {
            switch selection {
            case .recordings:
                RecordingsView(library: coordinator.library, coordinator: coordinator)
                    .navigationTitle("Recordings")
            case .jobs:
                JobsView(presets: coordinator.presets,
                         jobs: coordinator.jobs,
                         providers: coordinator.providers,
                         localModelsStore: coordinator.localModelsStore,
                         sidebarSelection: $selection)
                    .navigationTitle("Jobs")
            case .providers:
                ProvidersView(presets: coordinator.presets,
                              providers: coordinator.providers,
                              keychain: coordinator.keychain)
                    .navigationTitle("Providers")
            case .localModels:
                ModelsView(store: coordinator.localModelsStore)
            case .logs:
                LogsView(logs: coordinator.logs)
                    .navigationTitle("Logs")
            }
        }
        .background {
            WindowAccessor { window in
                lifecycleDelegate.install(on: window)
            }
        }
    }
}

enum SidebarDestination: Hashable {
    case recordings, jobs, providers, localModels, logs
}
