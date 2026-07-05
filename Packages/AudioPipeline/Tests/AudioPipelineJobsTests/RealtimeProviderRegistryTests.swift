// RealtimeProviderRegistryTests.swift
import Foundation
import Testing
@testable import AudioPipelineJobs

@Suite struct RealtimeProviderRegistryResolution {
    @Test func reson8IsStreamingCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "reson8") != nil)
    }
    @Test func unknownPresetIsNotCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "elevenlabs") == nil)
    }
    @Test func reson8ProviderBuildsASession() throws {
        let p = Reson8RealtimeProvider()
        let session = try p.makeSession(
            baseURL: "https://api.reson8.dev", apiKey: "k", language: "es",
            onEvent: { _ in }, onError: { _ in })
        #expect(session is Reson8RealtimeClient)
    }
    @Test func reson8ProviderThrowsOnBadBaseURL() {
        #expect(throws: Reson8RealtimeURL.BuildError.self) {
            _ = try Reson8RealtimeProvider().makeSession(
                baseURL: "api.reson8.dev", apiKey: "k", language: "en",
                onEvent: { _ in }, onError: { _ in })
        }
    }
    @Test func sonioxIsStreamingCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "soniox-async") != nil)
        #expect(RealtimeProviderRegistry.provider(for: "soniox") == nil)
    }
    @Test func sonioxProviderBuildsASession() throws {
        let session = try SonioxRealtimeProvider().makeSession(
            baseURL: "https://api.soniox.com", apiKey: "k", language: "en",
            onEvent: { _ in }, onError: { _ in })
        #expect(session is SonioxRealtimeClient)
    }
    @Test func deepgramIsStreamingCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "deepgram") != nil)
    }
    @Test func deepgramProviderBuildsASession() throws {
        let session = try DeepgramRealtimeProvider().makeSession(
            baseURL: "https://api.deepgram.com", apiKey: "k", language: "es",
            onEvent: { _ in }, onError: { _ in })
        #expect(session is DeepgramRealtimeClient)
    }
    @Test func deepgramProviderThrowsOnBadBaseURL() {
        #expect(throws: DeepgramRealtimeURL.BuildError.self) {
            _ = try DeepgramRealtimeProvider().makeSession(
                baseURL: "api.deepgram.com", apiKey: "k", language: "en",
                onEvent: { _ in }, onError: { _ in })
        }
    }
    @Test func openAIIsStreamingCapable() {
        #expect(RealtimeProviderRegistry.provider(for: "openai-gpt4o-transcribe") != nil)
    }
    @Test func openAIProviderBuildsASession() throws {
        let session = try OpenAIRealtimeProvider().makeSession(
            baseURL: "https://api.openai.com", apiKey: "k", language: "es",
            onEvent: { _ in }, onError: { _ in })
        #expect(session is OpenAIRealtimeClient)
    }
    @Test func openAIProviderThrowsOnBadBaseURL() {
        #expect(throws: OpenAIRealtimeURL.BuildError.self) {
            _ = try OpenAIRealtimeProvider().makeSession(
                baseURL: "api.openai.com", apiKey: "k", language: "en",
                onEvent: { _ in }, onError: { _ in })
        }
    }
}
