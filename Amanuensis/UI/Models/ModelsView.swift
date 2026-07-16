// ModelsView.swift
import SwiftUI
import LocalTranscription

struct ModelsView: View {
    @Bindable var store: LocalModelsStore

    private let columns = [GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(LocalModelCatalog.available) { model in
                    ModelCardView(
                        model: model,
                        state: store.states[model.id] ?? .init(),
                        isDictation: model.id == store.dictationModelID,
                        isInMemory: model.id == store.residentModelID,
                        isLoading: model.id == store.loadingModelID,
                        isUnloading: model.id == store.unloadingModelID,
                        onDownload: { Task { await store.download(model) } },
                        onDelete: { Task { await store.delete(model) } })
                }
            }
            .padding(16)
        }
        .task { await store.refresh() }
        .navigationTitle("Local Models")
    }
}
