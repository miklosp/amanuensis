import AVFoundation
import Foundation
import os
import RecordingStorage

// One in-progress recording. Owns both capture paths and the destination
// folder. Lifecycle is strictly create → start → stop; sessions are not
// reused.
@MainActor
public final class RecordingSession {
    public let folder: RecordingFolder
    private let mic: MicRecorder
    private let system: ProcessTapRecorder
    private var startedAt: Date?

    public init(folder: RecordingFolder) throws {
        self.folder = folder
        self.mic = try MicRecorder(url: folder.micURL)
        self.system = ProcessTapRecorder(url: folder.systemURL)
    }

    public func start() throws {
        let now = Date()
        startedAt = now
        // Start the system tap first; if it fails we haven't touched the mic
        // engine yet, so cleanup is trivial. If the mic fails to start after
        // the tap is live, tear the tap back down before propagating.
        try system.start()
        do {
            try mic.start()
        } catch {
            // start() is synchronous; fire-and-forget the async teardown.
            Task { await system.stop() }
            throw error
        }

        writeMetadata(stoppedAt: nil, mic: nil, system: nil)
    }

    public struct StopResult: Sendable {
        public let mic: RecordingTrackResult
        public let system: RecordingTrackResult?
    }

    public func stop() async -> StopResult {
        let stoppedAt = Date()
        let micResult = await mic.stop()
        let systemResult = await system.stop()
        writeMetadata(stoppedAt: stoppedAt, mic: micResult, system: systemResult)
        return StopResult(mic: micResult, system: systemResult)
    }

    private func writeMetadata(
        stoppedAt: Date?,
        mic: RecordingTrackResult?,
        system: RecordingTrackResult?
    ) {
        let started = startedAt ?? folder.startedAt
        let duration = stoppedAt.map { $0.timeIntervalSince(started) }
        let metadata = RecordingMetadata(
            folderName: folder.name,
            startedAt: started,
            stoppedAt: stoppedAt,
            durationSeconds: duration,
            mic: mic.map { Self.trackMetadata(from: $0) },
            system: system.map { Self.trackMetadata(from: $0) },
            hostAppVersion: Self.hostAppVersion,
            notes: nil
        )
        do {
            try metadata.write(to: folder.metadataURL)
        } catch {
            Self.log.error("metadata write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func trackMetadata(
        from result: RecordingTrackResult
    ) -> RecordingMetadata.TrackMetadata {
        RecordingMetadata.TrackMetadata(
            fileName: result.url.lastPathComponent,
            sampleRate: result.format.sampleRate,
            channelCount: Int(result.format.channelCount),
            formatID: "alac",
            framesWritten: result.framesWritten
        )
    }

    private static var hostAppVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    nonisolated private static let log = Logger(subsystem: "work.miklos.amanuensis", category: "session")
}
