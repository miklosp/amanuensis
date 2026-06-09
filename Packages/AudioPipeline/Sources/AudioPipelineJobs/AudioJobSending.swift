import Foundation

// Shape-neutral transport: given a Job + Provider + audio + key, returns the
// text to write to the output file. One conformer per JobShape handler;
// JobRunner dispatches to the right one by the job's shape.
public protocol AudioJobSending: Sendable {
    func send(job: Job, provider: Provider, audioURL: URL, apiKey: String) async throws -> String
}
