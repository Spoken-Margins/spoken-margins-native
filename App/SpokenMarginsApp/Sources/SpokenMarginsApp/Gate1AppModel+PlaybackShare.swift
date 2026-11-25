import Foundation
import SessionKit

extension Gate1AppModel {
    /// Share on the playback screen (#1507): the Share Margins sheet for this item opens on its review, with the
    /// default Margins selected and Share pinned at the bottom. Share, then Share again, is two taps to the iOS
    /// share sheet. What is playing pauses when the sheet begins and stays paused (#5050). The long Export screen is for a session export and
    /// stays under More.
    func openPlaybackShare() {
        openPlaybackShareStartingWithFriendAnswers() // a friend's item with the listener's answers opens on them (#3247)
    }
}
