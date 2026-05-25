import CoreFoundation
import Darwin
import Foundation
import os

// macOS system-audio-recording permission — the TCC service
// "kTCCServiceAudioCapture", which is separate from the microphone permission.
//
// There is no public API to request it. A Core Audio process tap created
// without this permission does NOT fail — it silently delivers digital
// silence — so the grant must be obtained before the tap starts. This uses the
// private TCC SPI, the same mechanism as the AudioCap reference implementation.
//
// Trade-off: depends on a private framework. Acceptable for Developer ID
// distribution; a hard blocker for Mac App Store review — a known M1 deferral.
public enum AudioCapturePermission {
    nonisolated private static let log = Logger(
        subsystem: "work.miklos.audio-pipeline",
        category: "permission"
    )

    nonisolated private static let service = "kTCCServiceAudioCapture"

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn =
        @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    // dlopen handle + resolved SPI symbols, resolved once on first use. The
    // unchecked annotation is the escape hatch for the non-Sendable C types;
    // all three are immutable after initialisation.
    nonisolated(unsafe) private static let tccHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    nonisolated(unsafe) private static let preflightSPI: PreflightFn? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessPreflight") else {
            return nil
        }
        return unsafeBitCast(symbol, to: PreflightFn.self)
    }()

    nonisolated(unsafe) private static let requestSPI: RequestFn? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessRequest") else {
            return nil
        }
        return unsafeBitCast(symbol, to: RequestFn.self)
    }()

    // True when system audio capture is already authorized (never prompts).
    nonisolated static func isAuthorized() -> Bool {
        guard let preflightSPI else { return false }
        // 0 = authorized, 1 = denied, 2 = undetermined.
        return preflightSPI(service as CFString, nil) == 0
    }

    // Ensures system audio capture is authorized, presenting the system prompt
    // once when the status is undetermined. Returns the final authorization.
    public nonisolated static func requestIfNeeded() async -> Bool {
        if isAuthorized() { return true }
        guard let requestSPI else {
            log.fault("TCCAccessRequest SPI unavailable — cannot request system audio access")
            return false
        }
        let granted: Bool = await withCheckedContinuation { continuation in
            requestSPI(service as CFString, nil) { result in
                continuation.resume(returning: result)
            }
        }
        log.info("system audio capture authorization → \(granted, privacy: .public)")
        return granted
    }
}
