import Foundation
import SessionKit

/// Keeps the narration and the app's session in step where the listener comes back (#1337). A found-on-phone export
/// showed narration playing with the snapshot empty and no mini player. The origin was a path that cleared the
/// snapshot without stopping the client (trashing the viewed item, fixed in #1650); this repairs the state if any
/// path does it again, so sound is never left without something on screen that controls it.
extension Gate1AppModel {
    /// What the mini player shows now, and the first cause that hides it.
    var miniPlayerVisibility: NarrationOwnership.MiniPlayerVisibility {
        NarrationOwnership.miniPlayerVisibility(
            hasSession: hasActiveSession,
            isDismissing: isDismissingMiniPlayer,
            onPlaybackScreen: screen == .playback,
            phase: snapshot.phase
        )
    }

    /// Looks for sound with no session and repairs it: show the engine's session if it is still playing, otherwise
    /// stop the client. Records why the mini player shows or not, beside the narration state, whenever there is a session or sound to explain.
    /// Safe to call at any time: with a session in the snapshot, or nothing playing, it only records.
    @discardableResult
    func reconcileNarrationOwnership(trigger: String) -> NarrationOwnership.Repair {
        let narration = narrationDiagnostics()
        var live: SessionSnapshot?
        if !hasActiveSession, let engine, engine.currentSession != nil {
            live = try? engine.syncPlaybackProgress()
        }
        let repair = NarrationOwnership.repair(
            appHasSession: hasActiveSession,
            engineSessionIsPlaying: live?.status.isPlaybackActive == true,
            narrationIsPlaying: PlaybackDiagnosticFields.narrationIsPlaying(narration)
        )
        switch repair {
        case .none:
            break
        case .adoptEngineSession:
            if let live { snapshot = live }
        case .stopNarration:
            try? speechPlaybackClient?.stop()
        }
        if repair != .none {
            recordDeveloperDiagnostic("playback.ownershipRepair", NarrationOwnership.repairRecord(
                trigger: trigger,
                repair: repair,
                itemToken: DeveloperDiagnosticRecording.token(live?.itemId ?? snapshot.itemId),
                sessionToken: DeveloperDiagnosticRecording.token(live?.sessionId ?? snapshot.sessionId),
                narration: narration
            ))
        }
        // An idle Library with quiet narration has nothing to explain, so it adds no record.
        if hasActiveSession || repair != .none || PlaybackDiagnosticFields.narrationIsPlaying(narration) {
            recordDeveloperDiagnostic("miniPlayer.visibility", NarrationOwnership.miniPlayerRecord(
                trigger: trigger,
                visibility: miniPlayerVisibility,
                narration: narration
            ))
        }
        return repair
    }
}
