import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct ProviderBaseURLTests {
    @Test func acceptsHTTPS() {
        #expect(Provider.isAcceptableBaseURL("https://api.openai.com/v1"))
    }

    @Test func acceptsHTTPLoopback() {
        #expect(Provider.isAcceptableBaseURL("http://localhost:4444/openai"))
        #expect(Provider.isAcceptableBaseURL("http://127.0.0.1:4444"))
    }

    @Test func rejectsHTTPRemote() {
        #expect(!Provider.isAcceptableBaseURL("http://example.com/"))
    }

    @Test func rejectsMissingScheme() {
        #expect(!Provider.isAcceptableBaseURL("example.com"))
    }

    @Test func rejectsEmpty() {
        #expect(!Provider.isAcceptableBaseURL(""))
    }
}
