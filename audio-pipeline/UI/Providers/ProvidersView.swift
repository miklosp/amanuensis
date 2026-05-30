import AudioPipelineJobs
import SwiftUI

struct ProvidersView: View {
    let presets: PresetsStore
    @Bindable var providers: ProvidersStore
    let keychain: KeychainStore

    @State private var selection: Provider.ID?

    private var sortedProviders: [Provider] {
        providers.providers.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        HSplitView {
            List(sortedProviders, selection: $selection) { provider in
                Text(provider.name).tag(Optional(provider.id))
            }
            .frame(minWidth: 200, idealWidth: 240)

            ProvidersDetailPane(
                provider: sortedProviders.first(where: { $0.id == selection }),
                presets: presets,
                keychain: keychain,
                onSave: { providers.upsert($0) }
            )
            .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addProvider()
                } label: {
                    Label("New Provider", systemImage: "plus")
                }
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sortedProviders.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        if let id = selection, sortedProviders.contains(where: { $0.id == id }) {
            return
        }
        selection = sortedProviders.first?.id
    }

    private func addProvider() {
        let draft = Provider.makeDraft(presets: presets)
        providers.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        providers.delete(id: id)
        selection = nil
    }
}

private struct ProvidersDetailPane: View {
    let provider: Provider?
    let presets: PresetsStore
    let keychain: KeychainStore
    let onSave: (Provider) -> Void

    var body: some View {
        if let provider {
            ProviderEditorView(initial: provider,
                               presets: presets,
                               keychain: keychain,
                               onSave: onSave)
                .id(provider.id)
        } else {
            ContentUnavailableView("Select a provider", systemImage: "key")
        }
    }
}
