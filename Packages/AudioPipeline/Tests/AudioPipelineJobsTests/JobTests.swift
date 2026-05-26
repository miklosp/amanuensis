import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobCodable {
    @Test func roundTrip_preservesAllFields() throws {
        let id = UUID()
        let job = Job(
            id: id,
            name: "Swedish lesson transcription",
            presetID: "openai-compat-chat",
            baseURL: "http://localhost:4444/openai",
            model: "gemini-flash",
            apiKeyRef: KeychainRef(account: "bifrost-local"),
            fields: ["prompt": "Transcribe...", "temperature": "0.2"],
            outputExt: "txt"
        )
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded == job)
    }

    @Test func id_isStable_acrossEdits() {
        let id = UUID()
        var job = Job(id: id, name: "a", presetID: "x", baseURL: "",
                      model: "", apiKeyRef: KeychainRef(account: ""),
                      fields: [:], outputExt: "txt")
        job.name = "b"
        #expect(job.id == id)
    }
}
