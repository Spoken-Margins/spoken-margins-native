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

    /// The fields of a `playback.state` record: the session's own state, the on-device player's and the client's.
    func playbackStateRecordFields() -> [String: String] {
        DeveloperDiagnosticRecording.playbackStateFields(
            snapshot,
            player: (speechPlaybackClient as? SupertonicSpeechPlaybackClient)?.playerDiagnostics() ?? [:],
            narration: narrationDiagnostics()
        )
    }

    /// What the resource policy reads from the phone now: heat, Low Power Mode, power source, memory backoff.
    func currentResourceConditions() -> SpeechEngineConditions {
        SupertonicResourcePolicy.currentConditions(isOnExternalPower: SupertonicResourcePolicy.isOnExternalPower())
    }

    /// Records a switch to the iOS voice that has no render failure code: the stop after a memory warning
    /// and the listener's own Stop under "On-device voice". The offset is where narration was reading.
    func recordAppFallbackEvent(code: String, reason: SpeechFallbackReason) {
        recordSupertonicFallbackEvent(
            code: code,
            reason: reason,
            conditions: currentResourceConditions(),
            offset: snapshot.currentTextStart ?? -1
        )
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
