import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct Reson8RealtimeURLBuilding {
    @Test func swapsHttpsToWss_andAppendsPath() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev")
        #expect(url.scheme == "wss")
        #expect(url.host == "api.reson8.dev")
        #expect(url.path == "/v1/speech-to-text/realtime")
    }

    @Test func trimsTrailingSlashOnBaseURL() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev/")
        #expect(url.path == "/v1/speech-to-text/realtime")
    }

    @Test func attachesDictationConfigQuery() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(q["encoding"] == "pcm_s16le")
        #expect(q["sample_rate"] == "16000")
        #expect(q["channels"] == "1")
        #expect(q["include_interim"] == "true")
        #expect(q["language"] == "en")
    }

    @Test func usesWsForLoopbackHttp() throws {
        let url = try Reson8RealtimeURL.make(baseURL: "http://127.0.0.1:8080")
        #expect(url.scheme == "ws")
    }

    @Test func rejectsSchemelessBaseURL() {
        #expect(throws: Reson8RealtimeURL.BuildError.self) {
            _ = try Reson8RealtimeURL.make(baseURL: "api.reson8.dev")
        }
    }
}
