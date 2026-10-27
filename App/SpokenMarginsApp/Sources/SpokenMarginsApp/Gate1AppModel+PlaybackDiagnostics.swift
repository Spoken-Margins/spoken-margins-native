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

    /// Records a `playback.state` when the status or target changes, and every 30 seconds while playing. The
    /// snapshot's `didSet` calls it. A snapshot that loses its item also gets a `playback.sessionCleared` (#1337).
    func recordPlaybackEventState(previous: SessionSnapshot) {
        if previous.itemId != nil, snapshot.itemId == nil {
            playbackEventRecording.record("playback.sessionCleared", PlaybackDiagnosticFields.sessionCleared(
                previousItemToken: DeveloperDiagnosticRecording.token(previous.itemId),
                previousSessionToken: DeveloperDiagnosticRecording.token(previous.sessionId),
                previousStatus: previous.status.rawValue,
                narration: narrationDiagnostics()
            ))
            // A snapshot that loses its session while the client still reads is repaired now, not at the next
            // foreground. After the assignment finishes, so the repair doesn't assign inside the observer; a path
            // that ended the session also stopped the client, so it finds nothing to do.
            if PlaybackDiagnosticFields.narrationIsPlaying(narrationDiagnostics()) {
                Task { @MainActor [weak self] in self?.reconcileNarrationOwnership(trigger: "session_cleared") }
            }
        }
        recordTapAnswer(previous: previous)
        let now = ProcessInfo.processInfo.systemUptime
        let changed = previous.status != snapshot.status || previous.targetId != snapshot.targetId
            || previous.lastFailure != snapshot.lastFailure
        guard changed || (snapshot.status.isPlaybackActive && now - lastPlaybackEventCheckpoint >= 30) else { return }
        lastPlaybackEventCheckpoint = now
        playbackEventRecording.record("playback.state", playbackStateRecordFields())
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
        SupertonicResourcePolicy.currentConditions()
    }

    /// Stops on-device rendering for the iOS voice, as the app and the listener's Stop do without a render
    /// failure code, and records the switch. The client also answers true when the iOS voice already
    /// reads, which only refreshes its stop reason, so an event is recorded only when the voice changed.
    func stopOnDeviceRenderingRecordingFallback(
        _ client: SupertonicSpeechPlaybackClient,
        returnsAutomatically: Bool = false,
        code: String,
        reason: SpeechFallbackReason
    ) throws -> Bool {
        let wasOnDevice = !client.isSystemVoiceActive
        guard try client.stopOnDeviceRenderingAndUseSystemSpeech(returnsAutomatically: returnsAutomatically) else { return false }
        if wasOnDevice {
            recordSupertonicFallbackEvent(
                code: code,
                reason: reason,
                conditions: currentResourceConditions(),
                offset: snapshot.currentTextStart ?? -1
            )
        }
        return true
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
