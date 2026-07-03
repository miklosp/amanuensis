import SwiftUI
import LocalTranscription

struct ModelCardView: View {
    let model: LocalModel
    let state: LocalModelsStore.ModelState
    let isDictation: Bool
    let isInMemory: Bool
    let isLoading: Bool
    let isUnloading: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void

    @State private var languagesExpanded = false

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var sizeText: String {
        state.isDownloaded ? fmt(state.installedBytes) : "~\(fmt(model.approxBytes))"
    }

    private var canExpandLanguages: Bool { model.supportedLanguages.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(model.summary)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            languagesRow
            if languagesExpanded { languageChips }
            Divider()
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.displayName).font(.headline)
            if model.recommended { badge("Recommended", .tint) }
            if isDictation { badge("Dictation", .tint) }
            if isInMemory { badge("In memory", .green) }
        }
    }

    private func badge(_ text: String, _ fill: some ShapeStyle) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(fill.opacity(0.2), in: Capsule())
    }

    @ViewBuilder private var languagesRow: some View {
        let label = Text("\(sizeText) · \(model.languages)")
            .font(.caption).foregroundStyle(.tertiary)
        if canExpandLanguages {
            Button {
                withAnimation(.snappy) { languagesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(languagesExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var languageChips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 30), spacing: 4)],
            alignment: .leading, spacing: 4
        ) {
            ForEach(model.supportedLanguages, id: \.self) { code in
                Text(code)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            if state.isDownloading {
                ProgressView(value: state.progress).frame(width: 90)
            } else if state.isDownloaded {
                if isLoading || isUnloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(isLoading ? "Loading…" : "Unloading…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .disabled(isLoading || isUnloading)
            } else {
                Button("Download", action: onDownload)
            }
        }
    }
}
