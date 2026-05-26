import Foundation

// Glue: fetch API key → call handler → write result file next to recording.
// Single-shape for the MVP slice; later shapes get their own sender protocol
// or a dispatch table inside the runner.
public struct JobRunner: Sendable {
    private let keychain: any KeychainProviding
    private let handler: any ChatCompletionsAudioSending

    public init(
        keychain: any KeychainProviding,
        handler: any ChatCompletionsAudioSending = DefaultChatCompletionsAudioSender()
    ) {
        self.keychain = keychain
        self.handler = handler
    }

    @discardableResult
    public func run(job: Job, audioURL: URL) async throws -> URL {
        let key = try await keychain.get(account: job.apiKeyRef.account)
        let text = try await handler.send(job: job, audioURL: audioURL, apiKey: key)
        let folder = audioURL.deletingLastPathComponent()
        let outURL = Self.uniqueOutputURL(in: folder, jobName: job.name, ext: job.outputExt)
        try Data(text.utf8).write(to: outURL, options: .atomic)
        return outURL
    }

    // Builds "combined-<sanitised-name>.<ext>" inside `folder`; appends " (N)"
    // to the stem if the path already exists. Sanitisation replaces "/" and ":"
    // only — leaves spaces and other punctuation untouched (they're valid in
    // macOS filenames).
    static func uniqueOutputURL(in folder: URL, jobName: String, ext: String) -> URL {
        let sanitised = jobName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = "combined-\(sanitised)"
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
