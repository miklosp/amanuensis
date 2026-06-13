import Foundation

// Renders a response body for a user-facing error/log line: decoded as UTF-8,
// newlines collapsed, truncated with a byte count when long. Shared by every job
// handler's SendError so a failure reaches the in-app log with the server's
// actual reason instead of a generic "operation couldn't be completed".
func describeResponseBody(_ data: Data, limit: Int = 1000) -> String {
    guard !data.isEmpty else { return "<empty body>" }
    let text = String(decoding: data.prefix(limit), as: UTF8.self)
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return data.count > limit ? "\(text)… (\(data.count) bytes)" : text
}
