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
    private let service: LocalTranscriptionService

    public init(service: LocalTranscriptionService) {
        self.service = service
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
        } catch { lastError = error.localizedDescription }
    }

    public func preload(modelID: String?) async {
        do {
            if let id = modelID { try await service.preload(modelID: id) }
            else { await service.unloadResident() }
            residentModelID = await service.residentModelID()
        } catch { lastError = error.localizedDescription }
    }
}
