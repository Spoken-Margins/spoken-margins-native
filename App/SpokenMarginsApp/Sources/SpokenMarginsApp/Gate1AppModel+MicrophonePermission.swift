import Foundation
import SessionKit
import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Reading and asking for the microphone permission (#217, #783).
extension Gate1AppModel {
    /// The permission state the primer reads. A test that injects only the request skips the line.
    func microphonePrimerStatus() -> PermissionPromptStatus? {
        if let microphonePermissionStatusOverride { return microphonePermissionStatusOverride() }
        return microphonePermissionRequest == nil ? Self.microphonePermissionStatus() : nil
    }

    /// #217: waits as long as the system prompt is up; a slow Allow is still a yes.
    func requestMicrophonePermission(timeoutSeconds: TimeInterval = 10) async -> Bool {
        if let microphonePermissionRequest { return await microphonePermissionRequest() }
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await SystemRecordingClient.requestRecordPermission() },
            currentStatus: { Self.microphonePermissionStatus() },
            timeout: .seconds(timeoutSeconds)
        )
        diagnostics["lastMicrophonePermissionResult"] = granted ? "granted" : "denied"
        return granted
    }

    nonisolated static func microphonePermissionStatus() -> PermissionPromptStatus {
        #if canImport(AVFoundation) && os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #else
        return .granted
        #endif
    }
}
