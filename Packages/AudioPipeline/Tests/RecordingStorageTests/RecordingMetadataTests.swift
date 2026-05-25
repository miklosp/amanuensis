import Foundation
import Testing
import RecordingStorage

@Suite struct RecordingMetadataTests {
    @Test func defaultSchemaVersionIsOne() {
        let metadata = RecordingMetadata(
            folderName: "x",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(metadata.schemaVersion == 1)
    }

    @Test func codable_roundTrip_withAllFieldsPopulated() throws {
        let original = makeMetadata()
        let encoded = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(RecordingMetadata.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func codable_roundTrip_withOptionalsNil() throws {
        let original = makeMetadata(
            stoppedAt: nil,
            durationSeconds: nil,
            mic: nil,
            system: nil,
            hostAppVersion: nil,
            notes: nil
        )
        let encoded = try Self.encoder.encode(original)
        let decoded = try Self.decoder.decode(RecordingMetadata.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func writeToDisk_thenRead_isEqual() throws {
        try withTempDirectory { tempURL in
            let original = makeMetadata()
            let url = tempURL.appending(path: "meta.json", directoryHint: .notDirectory)
            try original.write(to: url)

            let data = try Data(contentsOf: url)
            let decoded = try Self.decoder.decode(RecordingMetadata.self, from: data)
            #expect(decoded == original)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
