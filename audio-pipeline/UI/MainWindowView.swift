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
                         providers: coordinator.providers)
                    .navigationTitle("Jobs")
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
    case recordings, jobs
}
