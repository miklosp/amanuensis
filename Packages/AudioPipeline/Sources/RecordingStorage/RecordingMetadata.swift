import Foundation

// Declared without Codable here; conformance is in the nonisolated extension
// below so the synthesized encode/decode witnesses aren't MainActor-isolated.
public struct RecordingMetadata: Sendable {
    public var schemaVersion: Int = 1
    public var folderName: String
    public var startedAt: Date
    public var stoppedAt: Date?
    public var durationSeconds: Double?
    public var mic: TrackMetadata?
    public var system: TrackMetadata?
    public var hostAppVersion: String?
    public var notes: String?
    public var title: String?

    public init(
        folderName: String,
        startedAt: Date,
        schemaVersion: Int = 1,
        stoppedAt: Date? = nil,
        durationSeconds: Double? = nil,
        mic: TrackMetadata? = nil,
        system: TrackMetadata? = nil,
        hostAppVersion: String? = nil,
        notes: String? = nil,
        title: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.folderName = folderName
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.durationSeconds = durationSeconds
        self.mic = mic
        self.system = system
        self.hostAppVersion = hostAppVersion
        self.notes = notes
        self.title = title
    }

    public struct TrackMetadata: Sendable {
        public var fileName: String
        public var sampleRate: Double
        public var channelCount: Int
        public var formatID: String
        public var framesWritten: Int64

        public init(
            fileName: String,
            sampleRate: Double,
            channelCount: Int,
            formatID: String,
            framesWritten: Int64
        ) {
            self.fileName = fileName
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.formatID = formatID
            self.framesWritten = framesWritten
        }
    }

    public nonisolated func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    // The one place the meta.json date strategy is defined, so every reader
    // stays in sync with `write(to:)`'s encoder above. Returns a fresh decoder
    // per call; callers cache their own instance.
    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// Conformances in a nonisolated extension so the synthesized encode/decode
// witnesses are not MainActor-isolated (module default is MainActor).
nonisolated extension RecordingMetadata: Codable, Equatable {}
nonisolated extension RecordingMetadata.TrackMetadata: Codable, Equatable {}
