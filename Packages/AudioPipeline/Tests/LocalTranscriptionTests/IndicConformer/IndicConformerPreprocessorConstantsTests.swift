import Foundation
import Testing
@testable import LocalTranscription

private func makeBlob(magic: String = "IASRPC01",
                      nFFT: Int32 = 512, winLength: Int32 = 400,
                      nBins: Int32 = 257, nMels: Int32 = 80,
                      extraFloats: Int = 0) -> Data {
    var d = Data()
    d.append(contentsOf: Array(magic.utf8))
    for v in [nFFT, winLength, nBins, nMels] { var le = v.littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
    for f in [Float(0.97), Float(1e-5), Float(1e-5)] { var le = f; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
    let floatCount = Int(winLength) + Int(nMels) * Int(nBins) + extraFloats
    for _ in 0..<floatCount { var f = Float(0); withUnsafeBytes(of: &f) { d.append(contentsOf: $0) } }
    return d
}

private func write(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
    try data.write(to: url); return url
}

@Test func parsesValidBlob() throws {
    let c = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob()))
    #expect(c.window.count == 400)
    #expect(c.filterBank.count == 80 * 257)
    #expect(abs(c.preemphasis - 0.97) < 1e-6)
}

@Test func rejectsBadMagic() throws {
    #expect(throws: (any Error).self) {
        _ = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob(magic: "XXXXXXXX")))
    }
}

@Test func rejectsWrongShape() throws {
    #expect(throws: (any Error).self) {
        _ = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob(nMels: 40)))
    }
}

@Test func rejectsTrailingBytes() throws {
    #expect(throws: (any Error).self) {
        _ = try IndicConformerPreprocessorConstants.load(from: try write(makeBlob(extraFloats: 3)))
    }
}
