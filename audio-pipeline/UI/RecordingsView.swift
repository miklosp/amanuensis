import AppKit
import SwiftUI

struct RecordingsView: View {
    @Bindable var library: RecordingsLibrary
    @State private var selection: Set<RecordingItem.ID> = []
    @State private var pendingDelete: RecordingItem?

    var body: some View {
        Table(library.recordings, selection: $selection) {
            TableColumn("Name", value: \.name)
            TableColumn("Date") { Text($0.startedAt, format: .dateTime) }
            TableColumn("Duration") { Text(Self.durationText($0.duration)) }
            TableColumn("Size") { Text(Self.sizeText($0.sizeBytes)) }
            TableColumn("Format", value: \.formatSummary)
        }
        .frame(minWidth: 620, minHeight: 320)
        .onAppear { library.refresh() }
        .contextMenu(forSelectionType: RecordingItem.ID.self) { ids in
            if let item = ids.first.flatMap(item(for:)) {
                Button("Play") { play(item) }
                Button("Reveal in Finder") { reveal(item) }
                Button("Delete…", role: .destructive) { pendingDelete = item }
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

    private static func durationText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
