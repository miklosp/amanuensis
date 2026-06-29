import AudioPipelineJobs
import SwiftUI

struct JobsView: View {
    let presets: PresetsStore
    @Bindable var jobs: JobsStore
    @Bindable var providers: ProvidersStore
    @Binding var sidebarSelection: SidebarDestination

    @State private var selection: Job.ID?

    private var sortedJobs: [Job] {
        jobs.jobs.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func isBroken(_ job: Job) -> Bool {
        guard let id = job.providerID else { return true }
        return providers.provider(id: id) == nil
    }

    var body: some View {
        Group {
            if providers.providers.isEmpty {
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
                .disabled(providers.providers.isEmpty)
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
        guard let firstProvider else { return }
        var draft = Job.makeDraft()
        draft.providerID = firstProvider.id
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
    let onSave: (Job) -> Void

    var body: some View {
        if let job {
            JobEditorView(initial: job,
                          presets: presets,
                          providers: providers,
                          onSave: onSave)
                .id(job.id)
        } else {
            ContentUnavailableView("Select a job", systemImage: "wand.and.stars")
        }
    }
}
