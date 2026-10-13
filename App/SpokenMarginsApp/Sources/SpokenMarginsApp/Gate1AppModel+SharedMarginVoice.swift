import Foundation
import SessionKit

/// The shared Margin's voice controls the model decides: pause and resume from the transport, and Retry (#941).
/// The player, the health check on it and the system Now Playing line are `MarginVoicePlayer` (#993).
extension Gate1AppModel {
    func setImportedCommentaryPaused(_ paused: Bool) {
        guard playingImportedCommentary != nil else { return }
        if importedCommentaryPhase.isFailed {
            if !paused { retryImportedCommentary() }
            return
        }
        do {
            try marginVoicePlayer.setSharedPaused(paused)
        } catch {
            reportFailure(error, context: "Shared Margin resume failed")
        }
    }

    /// Retry after a failure: a fresh player, item and health record for the same Margin.
    func retryImportedCommentary() {
        guard let prompt = playingImportedCommentary, importedCommentaryPhase.isFailed else { return }
        listenToImportedCommentary(prompt)
    }
}
