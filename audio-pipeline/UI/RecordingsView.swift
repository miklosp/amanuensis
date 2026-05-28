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
            .task { await library.refresh() }
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
                Button("Move to Trash", role: .destructive) {
                    Task { await library.delete(item) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The recording folder will be moved to the Trash.")
            }
            .toolbar {
                Button {
                    Task { await library.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            // Recording-conversion footer is closer-in-time to a stop, so it
            // renders above the job footer when both are visible.
            if let activity = coordinator.recordingActivity {
                Divider()
                StatusFooterRow(text: activity)
            }
            if let activity = coordinator.jobActivity {
                Divider()
                StatusFooterRow(text: activity)
            }
        }
        .frame(minWidth: 620, minHeight: 320)
        .animation(.easeInOut(duration: 0.18), value: coordinator.jobActivity)
        .animation(.easeInOut(duration: 0.18), value: coordinator.recordingActivity)
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

private struct StatusFooterRow: View {
    let text: String

    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text(text)
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
