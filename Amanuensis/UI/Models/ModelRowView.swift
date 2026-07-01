// ModelRowView.swift
import SwiftUI
import LocalTranscription

struct ModelRowView: View {
    let model: LocalModel
    let state: LocalModelsStore.ModelState
    let isDictation: Bool
    let isInMemory: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(model.displayName).font(.headline)
                         if model.recommended { Text("Recommended").font(.caption2).padding(.horizontal, 6)
                             .background(.tint.opacity(0.2)).clipShape(Capsule()) }
                         if isDictation { Text("Dictation").font(.caption2).padding(.horizontal, 6)
                             .background(.tint.opacity(0.2)).clipShape(Capsule()) }
                         if isInMemory { Text("In memory").font(.caption2).padding(.horizontal, 6)
                             .background(.green.opacity(0.2)).clipShape(Capsule()) } }
                Text(model.summary).font(.subheadline).foregroundStyle(.secondary)
                Text("\(model.languages) · \(state.isDownloaded ? fmt(state.installedBytes) : "~\(fmt(model.approxBytes))")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isDownloading { ProgressView(value: state.progress).frame(width: 90) }
            else if state.isDownloaded { Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } }
            else { Button("Download", action: onDownload) }
        }.padding(.vertical, 4)
    }
}
