import Foundation

// Glue: fetch API key → dispatch to the handler for the job's shape → write
// result file next to recording. The shape is resolved by the caller from the
// provider's preset and passed in, so JobRunner stays free of PresetsStore.
public struct JobRunner: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unsupportedShape(JobShape)
    }

    private let keychain: any KeychainProviding
    private let handlers: [JobShape: any AudioJobSending]

    // The complete production handler set, passed verbatim as the default for
    // `handlers:` (the init replaces, not merges). Tests substitute a partial map.
    public static let defaultHandlers: [JobShape: any AudioJobSending] = [
        .chatCompletionsAudio: DefaultChatCompletionsAudioSender(),
        .transcriptionMultipart: DefaultTranscriptionMultipartSender(),
        .elevenLabsScribe: DefaultElevenLabsScribeSender(),
        .sonioxAsync: DefaultSonioxAsyncSender(),
    ]

    public init(
        keychain: any KeychainProviding,
        handlers: [JobShape: any AudioJobSending] = JobRunner.defaultHandlers
    ) {
        self.keychain = keychain
        self.handlers = handlers
    }

    @discardableResult
    public func run(job: Job, provider: Provider, shape: JobShape, audioURL: URL) async throws -> URL {
        guard let handler = handlers[shape] else {
            throw Error.unsupportedShape(shape)
        }
        let key = try await keychain.get(account: provider.apiKeyRef.account)
        let text = try await handler.send(job: job, provider: provider,
                                          audioURL: audioURL, apiKey: key)
        let folder: URL
        if let path = job.outputFolderPath, !path.isEmpty {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folder = audioURL.deletingLastPathComponent()
        }
        let recordingName = audioURL.deletingLastPathComponent().lastPathComponent
        let outURL = Self.uniqueOutputURL(in: folder, recordingName: recordingName,
                                          jobName: job.name, ext: job.outputExt)
        // Ensure the target folder exists (custom folder might not). Failure here
        // bubbles via the .write() call below, which is correct: better to throw
        // than silently produce no file.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: outURL, options: .atomic)
        return outURL
    }

    // Builds "<recordingName>-<sanitised job name>.<ext>" inside `folder`;
    // appends " (N)" to the stem if the path already exists. Sanitisation
    // replaces "/" and ":" only — leaves spaces and other punctuation untouched
    // (they're valid in macOS filenames). recordingName is already a folder name
    // on disk, so it needs no further sanitising.
    static func uniqueOutputURL(in folder: URL, recordingName: String, jobName: String, ext: String) -> URL {
        let sanitised = jobName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = "\(recordingName)-\(sanitised)"
        let candidate = folder.appendingPathComponent("\(base).\(ext)")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        var n = 1
        while true {
            let alt = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            if !FileManager.default.fileExists(atPath: alt.path) { return alt }
            n += 1
        }
    }
}
