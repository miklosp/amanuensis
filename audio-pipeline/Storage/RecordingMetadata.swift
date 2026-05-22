import Foundation

struct RecordingMetadata: Codable, Sendable {
    var schemaVersion: Int = 1
    var folderName: String
    var startedAt: Date
    var stoppedAt: Date?
    var durationSeconds: Double?
    var mic: TrackMetadata?
    var system: TrackMetadata?
    var hostAppVersion: String?
    var notes: String?

    struct TrackMetadata: Codable, Sendable {
        var fileName: String
        var sampleRate: Double
        var channelCount: Int
        var formatID: String
        var framesWritten: Int64
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
