import Foundation

public enum ModelStorage {
    public static func base() throws -> URL {
        let dir: URL
        // Opt-in override so a non-sandboxed process (e.g. `swift test`) can point
        // at the app's sandbox-container Models dir, which it otherwise can't see.
        if let override = ProcessInfo.processInfo.environment["AMANUENSIS_MODELS_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            dir = support.appendingPathComponent("Amanuensis/Models", isDirectory: true)
        }
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
