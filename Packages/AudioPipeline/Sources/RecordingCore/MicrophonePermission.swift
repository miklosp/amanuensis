import AVFoundation
import Foundation

// Microphone (AVCaptureDevice .audio) authorization. Pure permission gating —
// no recorder state. Mirrors AudioCapturePermission, which handles the system
// audio capture TCC grant.
public enum MicrophonePermission {
    // The current authorization status (never prompts).
    public static func currentStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // Ensures microphone capture is authorized, presenting the system prompt
    // once when the status is undetermined. Returns the final authorization.
    public static func requestIfNeeded() async -> Bool {
        switch currentStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
