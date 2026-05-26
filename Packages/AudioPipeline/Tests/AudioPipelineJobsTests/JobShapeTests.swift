import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct JobShapeBehavior {
    @Test func rawValues_areStable() {
        #expect(JobShape.chatCompletionsAudio.rawValue == "chatCompletionsAudio")
        #expect(JobShape.transcriptionMultipart.rawValue == "transcriptionMultipart")
        #expect(JobShape.elevenLabsScribe.rawValue == "elevenLabsScribe")
        #expect(JobShape.geminiGenerateContent.rawValue == "geminiGenerateContent")
    }

    @Test func codable_roundTrip() throws {
        for shape in JobShape.allCases {
            let data = try JSONEncoder().encode(shape)
            let decoded = try JSONDecoder().decode(JobShape.self, from: data)
            #expect(decoded == shape)
        }
    }
}
