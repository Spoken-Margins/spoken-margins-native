import Foundation
import SessionKit
import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

/// #1286: the microphone answers Add Margin works from. Production reads iOS; a test injects the status and the
/// request here. Both then take the same route through `beginInterjection` and the compact-control wrapper, so
/// the "already granted" path every second Margin takes is one a test can reach.
struct MarginMicrophoneAccess {
    let request: (() async -> Bool)?
    private let statusOverride: (() -> PermissionPromptStatus)?
    /// A test recorder injected with no permission story: iOS's answer can't matter to it, so it reads as
    /// granted and starts on the tap, as it always has. Production, and a test that injects a status or a
    /// request, start one main-actor turn later, so "Starting Margin..." shows before the recorder's start.
    let recordsOnTheTap: Bool

    init(recorderInjected: Bool, request: (() async -> Bool)?, status: (() -> PermissionPromptStatus)?) {
        self.request = request
        recordsOnTheTap = recorderInjected && request == nil && status == nil
        statusOverride = status ?? (recordsOnTheTap ? { .granted } : nil)
    }

    /// nil when a test injected only the request: no primer line, ask straight away.
    func status() -> PermissionPromptStatus? {
        if let statusOverride { return statusOverride() }
        return request == nil ? Self.systemStatus() : nil
    }

    @MainActor func record(_ start: @escaping @MainActor () -> Void) {
        guard !recordsOnTheTap else { return start() }
        Task { @MainActor in
            await Task.yield()
            start()
        }
    }

    /// Compact controls (Live Activity, widget, URL) show no primer: granted records, anything else asks first.
    @MainActor func recordFromCompactControl(ask: @escaping @MainActor () async -> Bool, then: @escaping @MainActor (Bool) -> Void) {
        if status() == .granted { return record { then(true) } }
        Task { @MainActor in then(await ask()) }
    }

    nonisolated static func systemStatus() -> PermissionPromptStatus {
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

/// Reading and asking for the microphone permission (#217, #783).
extension Gate1AppModel {
    /// #217: waits as long as the system prompt is up; a slow Allow is still a yes.
    func requestMicrophonePermission(timeoutSeconds: TimeInterval = 10) async -> Bool {
        if let request = microphoneAccess.request { return await request() }
        let granted = await PermissionPromptWait.awaitAnswer(
            request: { await SystemRecordingClient.requestRecordPermission() },
            currentStatus: { MarginMicrophoneAccess.systemStatus() },
            timeout: .seconds(timeoutSeconds)
        )
        diagnostics["lastMicrophonePermissionResult"] = granted ? "granted" : "denied"
        return granted
    }
}
