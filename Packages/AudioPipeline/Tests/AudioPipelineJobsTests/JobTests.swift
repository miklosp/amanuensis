import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let providerID = UUID()
        let job = Job(
            id: id,
            name: "Swedish lesson transcription",
            providerID: providerID,
            model: "gemini-flash",
            fields: ["prompt": "Transcribe...", "temperature": "0.2"],
            outputExt: "txt",
            outputFolderPath: "/Users/x/Documents/transcripts"
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
        var job = Job(id: id, name: "a", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        job.name = "b"
        #expect(job.id == id)
    }

    @Test func outputFolderPath_defaultsToNil() {
        let job = Job(name: "n", providerID: nil, model: "",
                      fields: [:], outputExt: "txt")
        #expect(job.outputFolderPath == nil)
    }
}
