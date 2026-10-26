import Foundation
import SessionKit
import SessionKitSupertonic

/// Writes `VoiceRenderTelemetry`'s events to Diagnostics (#2701): one `voicepace.chunk` per rendered chunk, one
/// `voicepace.switch` per voice change and one `voicepace.summary` when a listening session ends. The numbers
/// are worked out in SessionKit; this reads the phone's charging state and hands the events on, so
/// `Gate1AppModel` doesn't grow. Nothing here carries text, titles or addresses.
@MainActor
final class VoiceRenderTelemetryRecorder {
    private var telemetry: VoiceRenderTelemetry
    private let record: @MainActor (_ kind: String, _ fields: [String: String]) -> Void
    private let isCharging: @MainActor () -> Bool?

    init(
        chosenVoice: String,
        record: @escaping @MainActor (_ kind: String, _ fields: [String: String]) -> Void,
        isCharging: @escaping @MainActor () -> Bool? = { SupertonicResourcePolicy.isOnExternalPower() }
    ) {
        self.telemetry = VoiceRenderTelemetry(chosenVoice: chosenVoice)
        self.record = record
        self.isCharging = isCharging
    }

    func handle(_ event: VoiceTelemetryEvent) {
        let outputs = telemetry.handle(
            event,
            uptime: ProcessInfo.processInfo.systemUptime,
            isCharging: isCharging()
        )
        for output in outputs { record(output.kind, output.fields) }
    }

    /// The voice label for a Supertonic voice, as logged.
    static func supertonicVoiceLabel(_ voice: SupertonicVoiceID) -> String { "supertonic:\(voice.rawValue)" }
}

extension Gate1AppModel {
    /// The handler a speech playback client reports render pace, voice switches and its session line through (#2701).
    func voiceTelemetryHandler(chosenVoice: String) -> SupertonicSpeechPlaybackClient.VoiceTelemetryHandler {
        let recorder = VoiceRenderTelemetryRecorder(chosenVoice: chosenVoice) { [weak self] kind, fields in
            self?.recordDeveloperDiagnostic(kind, fields)
        }
        return { event in Task { @MainActor in recorder.handle(event) } }
    }
}
