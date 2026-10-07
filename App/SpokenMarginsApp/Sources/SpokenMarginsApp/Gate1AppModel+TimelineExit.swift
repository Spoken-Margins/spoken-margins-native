import Foundation

/// How the Timeline screen is left (#670).
extension Gate1AppModel {
    /// What the Timeline's Back button is called.
    var timelineExitTitle: String { "Now Playing" }

    /// The Timeline's Back button, and the empty Timeline's "Return to Now Playing".
    func leaveTimeline() {
        openPlayback()
    }
}
