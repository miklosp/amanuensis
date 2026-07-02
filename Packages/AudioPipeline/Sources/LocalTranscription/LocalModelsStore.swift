import Foundation

@MainActor @Observable public final class LocalModelsStore {
    public struct ModelState: Sendable, Equatable {
        public var isDownloaded = false
        public var isDownloading = false
        public var progress: Double = 0
        public var installedBytes: Int64 = 0
        public init() {}
    }

    public private(set) var states: [String: ModelState] = [:]
    public var lastError: String?
    public var dictationModelID: String?
    public private(set) var residentModelID: String?
    /// The model currently being loaded into memory (preload in flight), or nil.
    public private(set) var loadingModelID: String?
    /// The model currently being unloaded — set only once an unload drags past
    /// `unloadSpinnerDelay`, so fast unloads never flash a spinner.
    public private(set) var unloadingModelID: String?
    private let service: LocalTranscriptionService
    private let unloadSpinnerDelay: Duration

    public init(service: LocalTranscriptionService, unloadSpinnerDelay: Duration = .seconds(4)) {
        self.service = service
        self.unloadSpinnerDelay = unloadSpinnerDelay
        for m in LocalModelCatalog.all { states[m.id] = ModelState() }
    }

    public func refresh() async {
        for m in LocalModelCatalog.all {
            let downloaded = (try? await service.isDownloaded(modelID: m.id)) ?? false
            let bytes = downloaded ? ((try? await service.installedBytes(modelID: m.id)) ?? 0) : 0
            states[m.id, default: ModelState()].isDownloaded = downloaded
            states[m.id, default: ModelState()].installedBytes = bytes
        }
        residentModelID = await service.residentModelID()
    }

    public func download(_ model: LocalModel) async {
        states[model.id, default: ModelState()].isDownloading = true
        states[model.id, default: ModelState()].progress = 0
        do {
            try await service.download(modelID: model.id) { [weak self] p in
                Task { @MainActor in self?.states[model.id, default: ModelState()].progress = p }
            }
            states[model.id, default: ModelState()].isDownloaded = true
            states[model.id, default: ModelState()].installedBytes = (try? await service.installedBytes(modelID: model.id)) ?? 0
        } catch {
            lastError = error.localizedDescription
        }
        states[model.id, default: ModelState()].isDownloading = false
    }

    public func delete(_ model: LocalModel) async {
        do {
            try await service.delete(modelID: model.id)
            states[model.id, default: ModelState()].isDownloaded = false
            states[model.id, default: ModelState()].installedBytes = 0
            residentModelID = await service.residentModelID()          // resync after a resident delete unloads it
            if dictationModelID == model.id { dictationModelID = nil }  // stop advertising a deleted dictation model
        } catch { lastError = error.localizedDescription }
    }

    public func preload(modelID: String?) async {
        if let id = modelID {
            loadingModelID = id                       // spinner on immediately: loads are multi-second
            do { try await service.preload(modelID: id) }
            catch { lastError = error.localizedDescription }
            loadingModelID = nil
        } else {
            // Unloads are usually instant; only show the spinner if this one drags on.
            let doomed = residentModelID
            let spinner = Task { [weak self, unloadSpinnerDelay] in
                try? await Task.sleep(for: unloadSpinnerDelay)
                if !Task.isCancelled { self?.unloadingModelID = doomed }
            }
            await service.unloadResident()
            spinner.cancel()
            unloadingModelID = nil
        }
        residentModelID = await service.residentModelID()
    }
}
