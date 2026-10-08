import Foundation
import SessionKit
import SessionKitAudio

/// What the model records so an export names who paused narration or switched its voice (#1109).
/// The field builders are `PlaybackDiagnosticFields` in SessionKit.
extension Gate1AppModel {
    /// The narration client's own intent and voice for a `playback.state` record, whichever voice is chosen.
    func narrationDiagnostics() -> [String: String] {
        if let supertonic = speechPlaybackClient as? SupertonicSpeechPlaybackClient {
            return supertonic.narrationDiagnostics()
        }
        if let system = speechPlaybackClient as? SystemSpeechPlaybackClient {
            return PlaybackDiagnosticFields.narration(intent: system.diagnosticIntent, systemVoiceActive: true, standInPassage: false)
        }
        return [:]
    }

    /// Records a switch from the on-device voice to the iOS voice as its own timestamped playback event,
    /// with what the resource policy reads now beside the reason shown to the listener.
    func recordSupertonicFallbackEvent(
        code: String,
        reason: SpeechFallbackReason,
        conditions: SpeechEngineConditions,
        offset: Int
    ) {
        recordDeveloperDiagnostic("supertonic.fallback", PlaybackDiagnosticFields.supertonicFallback(
            code: code,
            reason: reason,
            policyBlock: SpeechEnginePolicy.onDeviceRenderingBlock(conditions),
            conditions: conditions,
            offset: offset
        ))
    }
}
