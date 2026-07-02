import Foundation

public enum ModelStorage {
    public static func base() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Amanuensis/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func runnerDir(_ runner: LocalRunner) throws -> URL {
        let dir = try base().appendingPathComponent(runner.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url,
              includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
