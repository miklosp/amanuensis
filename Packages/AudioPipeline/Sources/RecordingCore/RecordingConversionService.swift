import Foundation
import os

// Orchestrates background CAF→FLAC conversion for stopped recordings.
//
// Lives in the package so the app target only wires UI/state. Owns a
// dictionary of in-flight conversion tasks keyed by folder name so multiple
// concurrent conversions don't clobber each other — the original PR's
// `pendingConversion` single-slot design lost B's task reference when A's
// completion handler cleared it unconditionally.
//
// The combine operation is injected at init so tests can supply a controllable
// fake. The default uses `CombinedFLACExporter.combine`.
public actor RecordingConversionService {

    public struct Outcome: Sendable {
        public let folderName: String
        public let result: Result<Void, ConversionFailure>
    }

    public struct ConversionFailure: Error, Sendable {
        public let message: String
    }

    public typealias Combine = @Sendable (
        _ mic: URL, _ system: URL?, _ destination: URL
    ) async throws -> Void

    private let combine: Combine
    private var inflight: [String: Task<Outcome, Never>] = [:]

    public init(combine: @escaping Combine = { mic, system, destination in
        try await CombinedFLACExporter.combine(mic: mic, system: system, to: destination)
    }) {
        self.combine = combine
    }

    public func startConversion(
        folderName: String,
        mic: URL,
        system: URL?,
        destination: URL,
        keepSourcesOnSuccess: Bool
    ) -> Task<Outcome, Never> {
        let combine = self.combine
        let task = Task<Outcome, Never> { [weak self] in
            let outcome: Outcome
            do {
                try await combine(mic, system, destination)
                if !keepSourcesOnSuccess {
                    try? FileManager.default.removeItem(at: mic)
                    if let system {
                        try? FileManager.default.removeItem(at: system)
                    }
                }
                outcome = Outcome(folderName: folderName, result: .success(()))
            } catch {
                Self.log.error("conversion failed for \(folderName, privacy: .public): \(String(describing: error), privacy: .public)")
                outcome = Outcome(
                    folderName: folderName,
                    result: .failure(ConversionFailure(message: error.localizedDescription))
                )
            }
            await self?.clear(folderName: folderName)
            return outcome
        }
        inflight[folderName] = task
        return task
    }

    public func waitForConversion(folderName: String) async {
        guard let task = inflight[folderName] else { return }
        _ = await task.value
    }

    public func isConverting(folderName: String) -> Bool {
        inflight[folderName] != nil
    }

    private func clear(folderName: String) {
        inflight[folderName] = nil
    }

    private static let log = Logger(
        subsystem: "work.miklos.audio-pipeline",
        category: "conversion-service"
    )
}
