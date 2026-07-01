import AudioPipelineJobs
import LocalTranscription
import SwiftUI

struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    @Bindable var providers: ProvidersStore
    let localModelsStore: LocalModelsStore
    @Binding var sidebarSelection: SidebarDestination

    @State private var selection: Job.ID?

    private var sortedJobs: [Job] {
        jobs.jobs.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func isBroken(_ job: Job) -> Bool {
        switch TranscriptionSource(providerID: job.providerID) {
        case .none: return true
        case .local: return false
        case .provider(let id): return providers.provider(id: id) == nil
        }
    }

    // A local-only user (no cloud providers) can still create + run a Local job
    // once any on-device model is downloaded.
    private var hasLocalModel: Bool {
        LocalModelCatalog.all.contains { localModelsStore.states[$0.id]?.isDownloaded == true }
    }

    var body: some View {
        Group {
            if providers.providers.isEmpty && !hasLocalModel {
                ContentUnavailableView {
                    Label("No providers configured", systemImage: "key")
                } description: {
                    Text("Add a provider first.")
                } actions: {
                    Button("Go to Providers") {
                        sidebarSelection = .providers
                    }
                    .buttonStyle(.glassProminent)
                }
            } else {
                HStack(spacing: 0) {
                    List(sortedJobs, selection: $selection) { job in
                        HStack(spacing: 6) {
                            if isBroken(job) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Text(job.name)
                        }
                        .tag(Optional(job.id))
                    }
                    .frame(width: 240)

                    Divider()

                    JobsDetailPane(
                        job: sortedJobs.first(where: { $0.id == selection }),
                        presets: presets,
                        providers: providers,
                        localModelsStore: localModelsStore,
                        onSave: { jobs.upsert($0) }
                    )
                    .frame(minWidth: 420, maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    addJob()
                } label: {
                    Label("New Job", systemImage: "plus")
                }
                .disabled(providers.providers.isEmpty && !hasLocalModel)
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Label("Delete", systemImage: "minus")
                }
                .disabled(selection == nil)
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: sortedJobs.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: selection) { _, newValue in
            if newValue == nil { selectFirstIfNeeded() }
        }
    }

    private func selectFirstIfNeeded() {
        if let id = selection, sortedJobs.contains(where: { $0.id == id }) {
            return
        }
        selection = sortedJobs.first?.id
    }

    private func addJob() {
        let firstProvider = providers.providers
            .min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let providerID = firstProvider?.id ?? (hasLocalModel ? Provider.localID : nil) else { return }
        var draft = Job.makeDraft()
        draft.providerID = providerID
        jobs.upsert(draft)
        selection = draft.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        jobs.delete(id: id)
        selection = nil
    }
}

private struct JobsDetailPane: View {
    let job: Job?
    let presets: PresetsStore
    let providers: ProvidersStore
    let localModelsStore: LocalModelsStore
    let onSave: (Job) -> Void

    var body: some View {
        if let job {
            JobEditorView(initial: job,
                          presets: presets,
                          providers: providers,
                          localModelsStore: localModelsStore,
                          onSave: onSave)
                .id(job.id)
        } else {
            ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
        }
    }
}
