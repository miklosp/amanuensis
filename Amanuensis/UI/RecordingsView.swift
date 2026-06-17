import AppKit
import AudioPipelineJobs
import RecordingStorage
import SwiftUI

struct RecordingsView: View {
    @Bindable var library: RecordingsLibrary
    let coordinator: AppCoordinator
    @State private var selection: Set<RecordingItem.ID> = []
    @State private var pendingDelete: [RecordingItem] = []

    var body: some View {
        Table(library.recordings, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Date") { Text($0.startedAt, format: .dateTime) }
            TableColumn("Duration") { Text(RecordingFormatters.durationText($0.duration)) }
            TableColumn("Size") { Text(RecordingFormatters.sizeText($0.sizeBytes)) }
            TableColumn("Format", value: \.formatSummary)
        }
        .task { await library.refresh() }
        .contextMenu(forSelectionType: RecordingItem.ID.self) { ids in
            let items = items(for: ids)
            if let first = items.first {
                // Play / Reveal / Run Job are single-item actions; they
                // operate on the first selected row.
                Button("Play") { play(first) }
                Button("Reveal in Finder") { reveal(first) }

                if coordinator.jobs.jobs.isEmpty {
                    Text("No Jobs defined")
                } else {
                    Menu("Run Job") {
                        ForEach(coordinator.jobs.jobs) { job in
                            Button(job.name) {
                                Task {
                                    let result = await coordinator.runJob(job, on: first.folderURL)
                                    if case .success(let out) = result {
                                        NSWorkspace.shared.activateFileViewerSelecting([out])
                                    }
                                }
                            }
                        }
                    }
                }

                Button(deleteLabel(for: items.count), role: .destructive) {
                    pendingDelete = items
                }
            }
        } primaryAction: { ids in
            if let item = ids.first.flatMap(item(for:)) {
                NSWorkspace.shared.open(item.folderURL)
            }
        }
        .alert(
            deleteAlertTitle(for: pendingDelete),
            isPresented: Binding(
                get: { !pendingDelete.isEmpty },
                set: { if !$0 { pendingDelete = [] } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                let toDelete = pendingDelete
                pendingDelete = []
                Task {
                    for item in toDelete {
                        await library.delete(item)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteAlertMessage(for: pendingDelete.count))
        }
        .toolbar {
            Button {
                Task { await library.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private func item(for id: RecordingItem.ID) -> RecordingItem? {
        library.recordings.first { $0.id == id }
    }

    private func items(for ids: Set<RecordingItem.ID>) -> [RecordingItem] {
        // Preserve table order so the alert / actions are deterministic.
        library.recordings.filter { ids.contains($0.id) }
    }

    private func deleteLabel(for count: Int) -> String {
        count > 1 ? "Delete \(count) Recordings…" : "Delete…"
    }

    private func deleteAlertTitle(for items: [RecordingItem]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return "Delete “\(items[0].name)”?"
        default: return "Delete \(items.count) recordings?"
        }
    }

    private func deleteAlertMessage(for count: Int) -> String {
        count > 1
            ? "All \(count) selected recording folders will be moved to the Trash."
            : "The recording folder will be moved to the Trash."
    }

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
