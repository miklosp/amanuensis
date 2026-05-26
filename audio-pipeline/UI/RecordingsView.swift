import AppKit
import AudioPipelineJobs
import RecordingStorage
import SwiftUI

struct RecordingsView: View {
    @Bindable var library: RecordingsLibrary
    let coordinator: AppCoordinator
    @State private var selection: Set<RecordingItem.ID> = []
    @State private var pendingDelete: RecordingItem?

    var body: some View {
        VStack(spacing: 0) {
            Table(library.recordings, selection: $selection) {
                TableColumn("Name", value: \.name)
                TableColumn("Date") { Text($0.startedAt, format: .dateTime) }
                TableColumn("Duration") { Text(RecordingFormatters.durationText($0.duration)) }
                TableColumn("Size") { Text(RecordingFormatters.sizeText($0.sizeBytes)) }
                TableColumn("Format", value: \.formatSummary)
            }
            .onAppear { library.refresh() }
            .contextMenu(forSelectionType: RecordingItem.ID.self) { ids in
                if let item = ids.first.flatMap(item(for:)) {
                    Button("Play") { play(item) }
                    Button("Reveal in Finder") { reveal(item) }

                    if coordinator.jobs.jobs.isEmpty {
                        Text("No Jobs defined")
                    } else {
                        Menu("Run Job") {
                            ForEach(coordinator.jobs.jobs) { job in
                                Button(job.name) {
                                    Task {
                                        let result = await coordinator.runJob(job, on: item.folderURL)
                                        if case .success(let out) = result {
                                            NSWorkspace.shared.activateFileViewerSelecting([out])
                                        }
                                        // Failure case logged in AppCoordinator.runJob; UI surfacing deferred to post-MVP.
                                    }
                                }
                            }
                        }
                    }

                    Button("Delete…", role: .destructive) { pendingDelete = item }
                }
            } primaryAction: { ids in
                if let item = ids.first.flatMap(item(for:)) {
                    NSWorkspace.shared.open(item.folderURL)
                }
            }
            .alert(
                "Delete “\(pendingDelete?.name ?? "")”?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { item in
                Button("Move to Trash", role: .destructive) { library.delete(item) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The recording folder will be moved to the Trash.")
            }
            .toolbar {
                Button {
                    library.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            if let activity = coordinator.jobActivity {
                Divider()
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 620, minHeight: 320)
        .animation(.easeInOut(duration: 0.18), value: coordinator.jobActivity)
    }

    private func item(for id: RecordingItem.ID) -> RecordingItem? {
        library.recordings.first { $0.id == id }
    }

    // Opens the system track if present, otherwise the mic track.
    private func play(_ item: RecordingItem) {
        let candidates = ["system.flac", "system.caf", "mic.flac", "mic.caf"]
        for name in candidates {
            let url = item.folderURL.appending(path: name, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
    }

}
