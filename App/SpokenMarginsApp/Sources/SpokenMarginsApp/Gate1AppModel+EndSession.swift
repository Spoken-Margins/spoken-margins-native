import Foundation
import SessionKit

/// Closing the engine's session (#1036).
extension Gate1AppModel {
    /// The one place the app closes the engine's session. A playing Margin moment ends first, before the source is
    /// stopped, whichever path closes it: the mini player's X, Start New Session, or a chapter action restarting
    /// a finished session. A new session of the same item would otherwise leave the moment's closures alive.
    @discardableResult
    func endEngineSession(_ engine: SessionEngine, reason: PlaybackDiagnosticFields.SessionEndReason) throws -> SessionSnapshot {
        recordDeveloperDiagnostic("session.end", PlaybackDiagnosticFields.sessionEnd(
            reason: reason,
            itemToken: DeveloperDiagnosticRecording.token(snapshot.itemId),
            sessionToken: DeveloperDiagnosticRecording.token(snapshot.sessionId),
            narration: narrationDiagnostics()
        ))
        return try engine.endSession(stoppingInlinePlayback: endMarginMoment)
    }
}
