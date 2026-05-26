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
        let outURL = audioURL.deletingPathExtension().appendingPathExtension(job.outputExt)
        try text.data(using: .utf8)?.write(to: outURL, options: .atomic)
        return outURL
    }
}
