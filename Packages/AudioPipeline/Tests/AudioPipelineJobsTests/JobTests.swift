import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let providerID = UUID()
        let job = Job(
            name: "Swedish lesson transcription",
            providerID: providerID,
            model: "gemini-flash",
            fields: ["prompt": "Transcribe...", "temperature": "0.2"],
            outputExt: "txt",
            outputFolderPath: "/Users/x/Documents/transcripts",
            id: id
        )
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded == job)
        #expect(decoded.outputFolderPath == "/Users/x/Documents/transcripts")
        #expect(decoded.providerID == providerID)
    }

    @Test func roundTrip_preservesNilProviderID() throws {
        let job = Job(name: "draft", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded.providerID == nil)
    }

    @Test func id_isStable_acrossEdits() {
        let id = UUID()
        var job = Job(name: "a", providerID: nil, model: "",
                      fields: [:], outputExt: "txt", id: id)
        job.name = "b"
        #expect(job.id == id)
    }

    @Test func outputFolderPath_defaultsToNil() {
        let job = Job(name: "n", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        #expect(job.outputFolderPath == nil)
    }

    @Test func roundTrip_preservesOutputFolderBookmark() throws {
        let bookmark = Data([0x01, 0x02, 0x03])
        let job = Job(name: "n", providerID: nil, model: "",
                      fields: [:], outputExt: "txt",
                      outputFolderPath: "/Users/x/transcripts",
                      outputFolderBookmark: bookmark)
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded.outputFolderBookmark == bookmark)
    }

    @Test func outputFolderBookmark_defaultsToNil() {
        let job = Job(name: "n", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        #expect(job.outputFolderBookmark == nil)
    }

    // Jobs saved before the bookmark field existed must still decode (the key is
    // simply absent), leaving the bookmark nil so the run path re-prompts once.
    @Test func decodesLegacyJSON_withoutBookmarkKey() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","name":"n","model":"","fields":{},"outputExt":"txt","outputFolderPath":"/Users/x/transcripts"}"#
        let decoded = try JSONDecoder().decode(Job.self, from: Data(legacy.utf8))
        #expect(decoded.outputFolderPath == "/Users/x/transcripts")
        #expect(decoded.outputFolderBookmark == nil)
    }
}
