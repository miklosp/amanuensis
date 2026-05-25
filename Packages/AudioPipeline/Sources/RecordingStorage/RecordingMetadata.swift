import Foundation

public struct RecordingMetadata: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var folderName: String
    public var startedAt: Date
    public var stoppedAt: Date?
    public var durationSeconds: Double?
    public var mic: TrackMetadata?
    public var system: TrackMetadata?
    public var hostAppVersion: String?
    public var notes: String?

    public init(
        schemaVersion: Int = 1,
        folderName: String,
        startedAt: Date,
        stoppedAt: Date? = nil,
        durationSeconds: Double? = nil,
        mic: TrackMetadata? = nil,
        system: TrackMetadata? = nil,
        hostAppVersion: String? = nil,
        notes: String? = nil
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
    }

    public struct TrackMetadata: Codable, Sendable {
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

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
