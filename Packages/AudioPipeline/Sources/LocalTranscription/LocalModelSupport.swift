import Darwin
import Foundation

/// Whether this Mac can run the on-device transcription models. The engines
/// (FluidAudio, WhisperKit, IndicConformer) are tuned for the Apple Neural
/// Engine and are unusably slow — or fail to load — on Intel. Gate every
/// local-model surface on this so Intel machines never see, download, or
/// select local models.
public enum LocalModelSupport {
    /// `true` on Apple Silicon (Neural Engine present), `false` on Intel.
    /// Reads the hardware capability via sysctl, so it is correct regardless of
    /// which binary slice is executing (Intel slice, or arm64 under Rosetta).
    public static let isSupported: Bool = hasAppleSilicon()

    private static func hasAppleSilicon() -> Bool {
        #if DEBUG
        // Verification aid: simulate an Intel Mac on Apple Silicon by launching
        // with AMANUENSIS_FORCE_NO_LOCAL set, to confirm the local UI hides.
        if ProcessInfo.processInfo.environment["AMANUENSIS_FORCE_NO_LOCAL"] != nil {
            return false
        }
        #endif
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}
