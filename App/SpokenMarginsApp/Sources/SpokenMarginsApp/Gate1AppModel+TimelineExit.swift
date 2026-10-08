import Foundation

/// How the Timeline screen is left (#670).
extension Gate1AppModel {
    /// What the Timeline's Back button is called: Now Playing while a session exists, Home once it is closed.
    var timelineExitTitle: String { hasActiveSession ? "Now Playing" : "Home" }

    /// The Timeline's Back button, and the empty Timeline's "Return to Now Playing". The mini player on
    /// the Timeline can close the session while the listener stays on this page (#583), and
    /// `openPlayback()` does nothing without a session, so Back would be a dead button. Home always works.
    func leaveTimeline() {
        if hasActiveSession {
            openPlayback()
        } else {
            openHome()
        }
    }
}
