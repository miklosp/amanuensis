// RealtimeSTTTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct RealtimeSTTSeam {
    /// Thread-safe wrapper for events collected during test.
    final class EventBuffer: Sendable {
        nonisolated(unsafe) private var buffer: [TranscriptEvent] = []
        func append(_ event: TranscriptEvent) { buffer.append(event) }
        var contents: [TranscriptEvent] { buffer }
    }

    /// A minimal conformer proving the protocols are usable and the event type is value-equal.
    final class FakeSession: RealtimeSTTSession, @unchecked Sendable {
        nonisolated(unsafe) var started = false
        nonisolated(unsafe) var sent: [Data] = []
        nonisolated(unsafe) var finished = false
        func start() { started = true }
        func send(_ pcm: Data) { sent.append(pcm) }
        func finish() async { finished = true }
    }

    struct FakeProvider: RealtimeSTTProvider {
        func makeSession(baseURL: String, apiKey: String, language: String,
                         onEvent: @escaping @Sendable (TranscriptEvent) -> Void,
                         onError: @escaping @Sendable (Error) -> Void) throws -> RealtimeSTTSession {
            onEvent(.partial("hi"))
            return FakeSession()
        }
    }

    @Test func eventEquality() {
        #expect(TranscriptEvent.partial("a") == .partial("a"))
        #expect(TranscriptEvent.partial("a") != .final("a"))
    }

    @Test func providerYieldsEventsAndSession() async throws {
        let events = EventBuffer()
        let session = try FakeProvider().makeSession(
            baseURL: "https://x", apiKey: "k", language: "en",
            onEvent: { events.append($0) }, onError: { _ in })
        session.start()
        session.send(Data([0, 1]))
        await session.finish()
        #expect(events.contents == [.partial("hi")])
        let fake = session as? FakeSession
        #expect(fake?.started == true)
        #expect(fake?.sent.count == 1)
        #expect(fake?.finished == true)
    }

    @Test func reson8ClientIsARealtimeSession() {
        let url = try! Reson8RealtimeURL.make(baseURL: "https://api.reson8.dev")
        let client = Reson8RealtimeClient(url: url, apiKey: "k",
            onPartial: { _ in }, onFinal: { _ in })
        let session: RealtimeSTTSession = client   // compile-time proof of conformance
        _ = session
    }
}
