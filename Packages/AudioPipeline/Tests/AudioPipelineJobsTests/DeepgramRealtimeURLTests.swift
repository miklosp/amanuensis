// DeepgramRealtimeURLTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct DeepgramRealtimeURLBuilding {
    @Test func swapsHttpsToWss_andAppendsPath() throws {
        let url = try DeepgramRealtimeURL.make(baseURL: "https://api.deepgram.com")
        #expect(url.scheme == "wss")
        #expect(url.host == "api.deepgram.com")
        #expect(url.path == "/v1/listen")
    }

    @Test func trimsTrailingSlashOnBaseURL() throws {
        let url = try DeepgramRealtimeURL.make(baseURL: "https://api.deepgram.com/")
        #expect(url.path == "/v1/listen")
    }

    @Test func attachesDictationConfigQuery() throws {
        let url = try DeepgramRealtimeURL.make(baseURL: "https://api.deepgram.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(q["model"] == "nova-3")
        #expect(q["encoding"] == "linear16")
        #expect(q["sample_rate"] == "16000")
        #expect(q["channels"] == "1")
        #expect(q["interim_results"] == "true")
        #expect(q["smart_format"] == "true")
        #expect(q["endpointing"] == "300")
        #expect(q["language"] == "en")
    }

    @Test func languageOverridePassesThrough() throws {
        let url = try DeepgramRealtimeURL.make(
            baseURL: "https://api.deepgram.com",
            options: DeepgramRealtimeOptions(language: "es"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(q["language"] == "es")
    }

    @Test func usesWsForLoopbackHttp() throws {
        let url = try DeepgramRealtimeURL.make(baseURL: "http://127.0.0.1:8080")
        #expect(url.scheme == "ws")
    }

    @Test func rejectsSchemelessBaseURL() {
        #expect(throws: DeepgramRealtimeURL.BuildError.self) {
            _ = try DeepgramRealtimeURL.make(baseURL: "api.deepgram.com")
        }
    }
}
