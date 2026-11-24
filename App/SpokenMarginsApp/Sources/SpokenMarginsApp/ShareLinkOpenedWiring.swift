import Foundation
import SessionKit

/// The app's one copy of each opened-marks object (#5275). They live here, not on `Gate1AppModel`, which must not grow.
/// Both talk only to `ProductServer.host`, so a Debug build launched with `-SMServerHost offline.invalid` (J10, the
/// app-hosted tests) never reaches the real server.
extension SentLinkStatus {
    /// The sender's sent links, read by the Margins tab's item headings.
    static let shared = SentLinkStatus(file: .standard(), client: .live)
}

extension FriendLinkSignaller {
    /// Sends the friend's opened marks from the item screen's start controls. The listener's own links are never sent.
    static let shared = FriendLinkSignaller(signals: FriendLinkSignals(), client: .live, ownLinkIDs: { SentLinkStatus.shared.linkIDs })
}
