import Foundation
import Speech
import AVFoundation
import CoreMedia

/// On-device transcription engine backed by Apple's SpeechAnalyzer (macOS 26+).
///
/// Handles the `.appleSpeech` runner. Unlike the other engines, the model is the OS:
/// there are no downloaded weights on our storage — `SpeechTranscriber` uses per-locale
/// assets that Apple installs and manages via `AssetInventory`. So `download` maps to a
/// locale asset install + reservation, `isDownloaded` to "the resolved locale is
/// installed", `installedBytes` to 0 (no per-locale byte API), and `delete` to releasing
/// our reservation (the shared system asset may persist).
///
/// Transcription runs a fresh `SpeechAnalyzer` + `SpeechTranscriber` over the whole file per
/// call (batch, not streaming); word timings come from the `audioTimeRange` result attribute.
@available(macOS 26, *)
public actor AppleSpeechEngine: LocalTranscriptionEngine {
    public init() {}

    // MARK: - Locale resolution

    /// Map a locale (or bare-language-code locale) to a SpeechTranscriber-supported locale.
    /// Tries Apple's equivalence first, then scans supportedLocales by language code, so a
    /// bare 2-letter code (the catalog's vocabulary, e.g. "en") resolves to a supported
    /// regional variant (en-US) instead of failing.
    private func supportedLocale(matching locale: Locale) async -> Locale? {
        if let eq = await SpeechTranscriber.supportedLocale(equivalentTo: locale) { return eq }
        guard let lang = locale.language.languageCode?.identifier else { return nil }
        return await SpeechTranscriber.supportedLocales.first { $0.language.languageCode?.identifier == lang }
    }

    /// Map an app language code (2-letter, e.g. "en") or nil to a concrete locale that
    /// SpeechTranscriber supports. An explicit-but-unsupported choice throws (never a
    /// silent wrong-language fallback); nil falls back to the system locale, then en-US.
    func resolveLocale(_ language: String?) async throws -> Locale {
        if let code = language?.trimmingCharacters(in: .whitespaces), !code.isEmpty {
            if let m = await supportedLocale(matching: Locale(identifier: code)) { return m }
            throw LocalTranscriptionError.transcriptionFailed("Language \"\(code)\" isn't available for Apple Speech.")
        }
        if let sys = await supportedLocale(matching: Locale.current) { return sys }
        if let en = await supportedLocale(matching: Locale(identifier: "en-US")) { return en }
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
        // Drive coarse progress around the install + reserve step. (A KVO/AsyncSequence bridge
        // can refine this later; ensureInstalled awaits completion regardless.)
        progress(0)
        try await ensureInstalled(locale)
        progress(1)
    }

    public func delete(_ model: LocalModel) async throws {
        // We don't force-delete a shared system asset; we relinquish our reservation.
        guard let locale = try? await resolveLocale(model.defaultLanguage) else { return }
        await AssetInventory.release(reservedLocale: locale)
    }

    // MARK: - LocalTranscriptionEngine (transcription)

    /// One batch run: build a transcriber for `locale` (optionally with word time ranges),
    /// feed the whole file through a fresh analyzer, and collect finalized results.
    /// Returns the concatenated AttributedString so callers derive plain text or timings.
    private func runAnalyzer(audioURL: URL, locale: Locale, timed: Bool) async throws -> AttributedString {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],                        // batch: final results only
            attributeOptions: timed ? [.audioTimeRange] : [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: audioURL)

        let collector = Task {
            var acc = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                acc.append(result.text)
            }
            return acc
        }
        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch is CancellationError {
            collector.cancel()
            throw CancellationError()   // honor cancellation; don't mask it as a transcription failure
        } catch {
            collector.cancel()
            throw LocalTranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    public func transcribe(audioURL: URL, model: LocalModel, language: String?) async throws -> String {
        let locale = try await resolveLocale(language)
        try await ensureInstalled(locale)
        let acc = try await runAnalyzer(audioURL: audioURL, locale: locale, timed: false)
        return String(acc.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribeTimed(audioURL: URL, model: LocalModel, language: String?) async throws -> [TimedWord] {
        let locale = try await resolveLocale(language)
        try await ensureInstalled(locale)
        let acc = try await runAnalyzer(audioURL: audioURL, locale: locale, timed: true)
        let words = Self.timedWords(from: acc)
        if words.isEmpty {
            // Text but no timings → let the diarized path degrade to plain, no second pass.
            throw LocalTranscriptionError.timingsUnavailable(
                plainText: String(acc.characters).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return words
    }

    public func preload(_ model: LocalModel) async throws {
        // Warm the locale asset so the first real transcription doesn't pay install latency.
        let locale = try await resolveLocale(model.defaultLanguage)
        try await ensureInstalled(locale)
    }

    public func unloadResident() async {}   // nothing retained between runs

    // MARK: - Per-language installer support

    /// App-facing 2-letter codes the OS supports (deduped from SpeechTranscriber.supportedLocales).
    func availableLocaleCodes() async -> [String] {
        let locales = await SpeechTranscriber.supportedLocales
        return Array(Set(locales.compactMap { $0.language.languageCode?.identifier })).sorted()
    }

    func installedLocaleCodes() async -> [String] {
        let locales = await SpeechTranscriber.installedLocales
        return Array(Set(locales.compactMap { $0.language.languageCode?.identifier })).sorted()
    }

    func maxReservedLocales() async -> Int { AssetInventory.maximumReservedLocales }

    /// The user's macOS preferred languages that Apple Speech supports — the default check set.
    func systemPreferredCodes() async -> [String] {
        let supported = Set(await availableLocaleCodes())
        return Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .filter { supported.contains($0) }
    }

    func install(localeCode: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await supportedLocale(matching: Locale(identifier: localeCode)) else {
            throw LocalTranscriptionError.transcriptionFailed("Language \"\(localeCode)\" isn't available for Apple Speech.")
        }
        if await AssetInventory.reservedLocales.count >= AssetInventory.maximumReservedLocales,
           !(await AssetInventory.reservedLocales.contains { $0.identifier == locale.identifier }) {
            throw LocalTranscriptionError.transcriptionFailed(
                "Apple Speech allows at most \(AssetInventory.maximumReservedLocales) reserved languages. Remove one first.")
        }
        progress(0)
        try await ensureInstalled(locale)
        progress(1)
    }

    func release(localeCode: String) async throws {
        guard let locale = await supportedLocale(matching: Locale(identifier: localeCode)) else { return }
        await AssetInventory.release(reservedLocale: locale)
    }
}

@available(macOS 26, *)
public extension AppleSpeechEngine {
    /// Extract per-run words + seconds from a transcription's AttributedString. Each run
    /// that carries the Speech time-range attribute becomes one `TimedWord`; untimed runs
    /// (rare, e.g. joins) are skipped. `text[run.range]` is the run's substring.
    nonisolated static func timedWords(from text: AttributedString) -> [TimedWord] {
        var out: [TimedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            out.append(TimedWord(
                text: piece,
                start: CMTimeGetSeconds(range.start),
                end: CMTimeGetSeconds(range.end)))
        }
        return out
    }
}
