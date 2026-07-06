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

    public typealias ExportTrack = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    private let combine: Combine
    private let exportTrack: ExportTrack
    private var inflight: [String: Task<Outcome, Never>] = [:]

    public init(
        combine: @escaping Combine = { mic, system, destination in
            try await CombinedFLACExporter.combine(mic: mic, system: system, to: destination)
        },
        exportTrack: @escaping ExportTrack = { source, destination in
            try await CombinedFLACExporter.exportTrack(source: source, to: destination)
        }
    ) {
        self.combine = combine
        self.exportTrack = exportTrack
    }

    public func startConversion(
        folderName: String,
        mic: URL,
        system: URL?,
        destination: URL,
        micFlac: URL,
        systemFlac: URL?,
        keepSourcesOnSuccess: Bool,
        keepSeparateTracks: Bool
    ) -> Task<Outcome, Never> {
        if let existing = inflight[folderName] { return existing }
        let combine = self.combine
        let exportTrack = self.exportTrack
        let task = Task.detached(priority: .utility) {
            let outcome: Outcome
            do {
                try await combine(mic, system, destination)
                // Per channel: optionally export the FLAC, then delete the raw
                // .caf only if that channel's audio survives elsewhere. combined.flac
                // is a mono SUM, so it cannot preserve an individual channel — a raw
                // .caf is deleted only when its separate track was actually produced
                // (or separate tracks weren't requested in the first place).
                await Self.processTrack(
                    caf: mic, flac: micFlac,
                    keepSeparateTracks: keepSeparateTracks,
                    keepSourcesOnSuccess: keepSourcesOnSuccess,
                    exportTrack: exportTrack)
                if let system {
                    await Self.processTrack(
                        caf: system, flac: systemFlac,
                        keepSeparateTracks: keepSeparateTracks,
                        keepSourcesOnSuccess: keepSourcesOnSuccess,
                        exportTrack: exportTrack)
                }
                outcome = Outcome(folderName: folderName, result: .success(()))
            } catch {
                Self.log.error("conversion failed for \(folderName, privacy: .public): \(String(describing: error), privacy: .public)")
                outcome = Outcome(
                    folderName: folderName,
                    result: .failure(ConversionFailure(message: error.localizedDescription))
                )
            }
            await self.clear(folderName: folderName)
            return outcome
        }
        inflight[folderName] = task
        return task
    }

    /// Export one channel's FLAC (when requested) and delete its raw `.caf` only
    /// if the channel's audio is preserved elsewhere. The raw `.caf` is deleted
    /// only when the caller opted out of keeping sources AND either separate
    /// tracks weren't requested, or the FLAC export for this channel succeeded.
    /// A failed export therefore never leaves the channel with no recoverable
    /// audio — `combined.flac` is a mono sum and cannot stand in for one channel.
    private static func processTrack(
        caf: URL,
        flac: URL?,
        keepSeparateTracks: Bool,
        keepSourcesOnSuccess: Bool,
        exportTrack: ExportTrack
    ) async {
        var separateTrackProduced = false
        if keepSeparateTracks, let flac {
            do {
                try await exportTrack(caf, flac)
                separateTrackProduced = true
            } catch {
                Self.log.error("failed to export FLAC for \(caf.lastPathComponent, privacy: .public); keeping .caf: \(String(describing: error), privacy: .public)")
            }
        }
        guard !keepSourcesOnSuccess else { return }
        // Keep the .caf when a separate track was requested but its export failed.
        if keepSeparateTracks && !separateTrackProduced { return }
        do {
            try FileManager.default.removeItem(at: caf)
        } catch {
            Self.log.error("failed to remove \(caf.lastPathComponent, privacy: .public) after conversion: \(String(describing: error), privacy: .public)")
        }
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

    nonisolated private static let log = Logger(
        subsystem: "work.miklos.amanuensis",
        category: "conversion-service"
    )
}
