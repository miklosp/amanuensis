import Foundation

// Builds a `multipart/form-data` request body, shared by the multipart upload
// handlers (TranscriptionMultipart, ElevenLabs Scribe). Callers add text fields
// and one file part; the boundary, framing and matching Content-Type header live
// here so the wire format stays byte-identical across handlers. Handlers still
// own what differs: the endpoint, the model field name, the file Content-Type
// and the auth header.
struct MultipartFormBody {
    let boundary = "Boundary-\(UUID().uuidString)"
    private var body = Data()

    var contentTypeHeader: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data fileData: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")
    }

    // Appends the closing boundary and returns the finished body. Mutating (not a
    // copy) so the audio bytes aren't duplicated.
    mutating func finished() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    // Foundation has no String→Data append; kept as a private method rather than a
    // file-local `extension Data` (which the linter flags as same-file grouping).
    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
