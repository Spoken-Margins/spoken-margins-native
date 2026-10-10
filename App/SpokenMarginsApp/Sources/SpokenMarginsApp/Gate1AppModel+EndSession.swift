import Foundation
import SessionKit

/// Closing the engine's session (#1036).
extension Gate1AppModel {
    /// The one place the app closes the engine's session. A playing Margin moment ends first, before the source is
    /// stopped, whichever path closes it: the mini player's X, Start New Session, or a chapter action restarting
    /// a finished session. A new session of the same item would otherwise leave the moment's closures alive.
    @discardableResult
    func endEngineSession(_ engine: SessionEngine) throws -> SessionSnapshot {
        try engine.endSession(stoppingInlinePlayback: endMarginMoment)
    }
}
