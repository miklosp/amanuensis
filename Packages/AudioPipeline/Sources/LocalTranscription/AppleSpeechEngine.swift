import Foundation
import Speech
import AVFoundation

/// On-device transcription engine backed by Apple's SpeechAnalyzer (macOS 26+).
///
/// Handles the `.appleSpeech` runner. Unlike the other engines, the model is the OS:
/// there are no downloaded weights on our storage — `SpeechTranscriber` uses per-locale
/// assets that Apple installs and manages via `AssetInventory`. So `download` maps to a
/// locale asset install + reservation, `isDownloaded` to "the resolved locale is
/// installed", `installedBytes` to 0 (no per-locale byte API), and `delete` to releasing
/// our reservation (the shared system asset may persist).
///
/// `transcribe` is a placeholder for now — Task 3 wires up the real `SpeechAnalyzer`
/// transcription path (and overrides `transcribeTimed`/`preload`/`unloadResident`).
@available(macOS 26, *)
public actor AppleSpeechEngine: LocalTranscriptionEngine {
    public init() {}

    // MARK: - Locale resolution

    /// Map an app language code (2-letter, e.g. "en") or nil to a concrete locale that
    /// SpeechTranscriber supports. An explicit-but-unsupported choice throws (never a
    /// silent wrong-language fallback); nil falls back to the system locale, then en-US.
    func resolveLocale(_ language: String?) async throws -> Locale {
        if let code = language?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code)) {
                return supported
            }
            throw LocalTranscriptionError.transcriptionFailed("Language \"\(code)\" isn't available for Apple Speech.")
        }
        if let sys = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return sys }
        if let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) { return en }
        throw LocalTranscriptionError.transcriptionFailed("No supported Apple Speech locale on this device.")
    }

    /// Install the locale asset if it isn't already, and reserve it so the system won't
    /// reclaim it. `assetInstallationRequest` returns nil when nothing needs installing.
    func ensureInstalled(_ locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        if !installed {
            let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - LocalTranscriptionEngine (asset management)

    public func isDownloaded(_ model: LocalModel) async -> Bool {
        // "Downloaded" == the resolved default locale's asset is installed. transcribe()
        // self-heals for any other requested language, so this is just the baseline signal.
        guard let locale = try? await resolveLocale(model.defaultLanguage) else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
    }

    public func installedBytes(_ model: LocalModel) async -> Int64 { 0 }  // no per-locale byte API

    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw LocalTranscriptionError.transcriptionFailed("Apple Speech isn't available on this device.")
        }
        let locale = try await resolveLocale(model.defaultLanguage)
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            // Drive coarse progress off the request's Progress. (A KVO/AsyncSequence bridge
            // can refine this later; downloadAndInstall() awaits completion regardless.)
            progress(0)
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        progress(1)
    }

    public func delete(_ model: LocalModel) async throws {
        // We don't force-delete a shared system asset; we relinquish our reservation.
        guard let locale = try? await resolveLocale(model.defaultLanguage) else { return }
        await AssetInventory.release(reservedLocale: locale)
    }

    // MARK: - LocalTranscriptionEngine (transcription — Task 3)

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        throw LocalTranscriptionError.transcriptionFailed("Apple Speech transcription is not yet implemented.")
    }
}
