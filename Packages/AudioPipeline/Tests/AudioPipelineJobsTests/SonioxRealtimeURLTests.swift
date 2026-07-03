// SonioxRealtimeURLTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct SonioxRealtimeURLBuilding {
    @Test func isSecureWebSocket() {
        let url = SonioxRealtimeURL.make()
        #expect(url.scheme == "wss")
        #expect(url.host == "stt-rt.soniox.com")
        #expect(url.path == "/transcribe-websocket")
    }
}
