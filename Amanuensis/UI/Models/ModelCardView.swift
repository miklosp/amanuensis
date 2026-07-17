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
    let store: LocalModelsStore

    @State private var languagesExpanded = false
    @State private var seeAllLanguages = false

    // Card typography floor: nothing below 14pt.
    private static let titleFont = Font.system(size: 16, weight: .semibold)
    private static let bodyFont = Font.system(size: 14)
    private static let codeFont = Font.system(size: 14, design: .monospaced)

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var sizeText: String {
        if model.approxBytes == 0 { return "System" }
        return state.isDownloaded ? fmt(state.installedBytes) : "~\(fmt(model.approxBytes))"
    }

    private var canExpandLanguages: Bool { model.supportedLanguages.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(model.summary)
                .font(Self.bodyFont).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.runner == .appleSpeech {
                appleSpeechSection
            } else {
                languagesRow
                if languagesExpanded { languageChips }
                Divider()
                footer
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .task {
            guard model.runner == .appleSpeech, store.appleLocales.available.isEmpty else { return }
            await store.refreshAppleLocales()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.displayName).font(Self.titleFont)
            if model.recommended { badge("Recommended", .tint) }
            if isDictation { badge("Dictation", .tint) }
            if isInMemory { badge("In memory", .green) }
        }
    }

    private func badge(_ text: String, _ fill: some ShapeStyle) -> some View {
        Text(text).font(Self.bodyFont)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(fill.opacity(0.2), in: Capsule())
    }

    // MARK: - Apple Speech per-language installer

    /// The system model's languages are managed per-language by Apple, so the card shows a
    /// live installer instead of a fixed download: installed languages (removable) on top,
    /// a one-tap "Download <your languages>" for the system-preferred set, and a "See all"
    /// toggle revealing every remaining supported language. Nothing installs on its own —
    /// each download is an explicit tap.
    @ViewBuilder private var appleSpeechSection: some View {
        let a = store.appleLocales
        let installed = a.installed.sorted()
        let suggestedToDownload = a.suggested.subtracting(a.installed).sorted()
        let notInstalled = a.available.filter { !a.installed.contains($0) }.sorted()

        Text(a.available.isEmpty ? "System · system-managed"
                                 : "System · \(a.available.count) languages")
            .font(Self.bodyFont).foregroundStyle(.tertiary)

        if !installed.isEmpty {
            localeGrid(installed) { localeChip($0, installed: true) }
        }

        if !suggestedToDownload.isEmpty {
            Button("Download \(suggestedToDownload.joined(separator: ", "))") {
                Task { await store.downloadSuggestedAppleLocales() }
            }
            .font(Self.bodyFont)
        }

        if !notInstalled.isEmpty {
            Button {
                withAnimation(.snappy) { seeAllLanguages.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(seeAllLanguages ? "Hide languages" : "See all languages")
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(seeAllLanguages ? 90 : 0))
                }
                .font(Self.bodyFont)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            if seeAllLanguages {
                localeGrid(notInstalled) { localeChip($0, installed: false) }
            }
        }
    }

    private func localeGrid<Chip: View>(
        _ codes: [String], @ViewBuilder _ chip: @escaping (String) -> Chip
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            ForEach(codes, id: \.self) { chip($0) }
        }
    }

    /// One language pill. Installed → code + trash (tap removes); not installed → code +
    /// download (tap installs). While the install/release is in flight, a spinner replaces
    /// the icon and the pill is disabled.
    private func localeChip(_ code: String, installed: Bool) -> some View {
        let busy = store.appleLocales.inFlight.contains(code)
        return Button {
            Task { await store.toggleAppleLocale(code, install: !installed) }
        } label: {
            HStack(spacing: 4) {
                Text(code).font(Self.codeFont)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: installed ? "trash" : "arrow.down.circle")
                        .font(Self.bodyFont)
                        .foregroundStyle(installed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(installed ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quinary),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(installed ? "Remove \(code)" : "Download \(code)")
    }

    // MARK: - Generic (non-Apple) rows

    @ViewBuilder private var languagesRow: some View {
        let label = Text("\(sizeText) · \(model.languages)")
            .font(Self.bodyFont).foregroundStyle(.tertiary)
        if canExpandLanguages {
            Button {
                withAnimation(.snappy) { languagesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "chevron.right")
                        .font(Self.bodyFont).foregroundStyle(.tertiary)
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
            columns: [GridItem(.adaptive(minimum: 40), spacing: 4)],
            alignment: .leading, spacing: 4
        ) {
            ForEach(model.supportedLanguages, id: \.self) { code in
                Text(code)
                    .font(Self.codeFont)
                    .padding(.horizontal, 6).padding(.vertical, 2)
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
                            .font(Self.bodyFont).foregroundStyle(.secondary)
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .font(Self.bodyFont)
                .disabled(isLoading || isUnloading)
            } else {
                Button("Download", action: onDownload)
                    .font(Self.bodyFont)
            }
        }
    }
}
