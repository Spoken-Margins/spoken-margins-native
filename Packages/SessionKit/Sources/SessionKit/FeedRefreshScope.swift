import Foundation

/// Which followed feeds a refresh pass covers (#4388). Every pass covers all of them, except the launch pass in Low Power
/// Mode: iOS turns off background app refresh there, so every feed is stale at open, and re-fetching all of them
/// (the owner follows 41) would run the most work on a slowed CPU and radio. That pass covers the feeds the first screen
/// of Following shows. The rest stay stale, and the next pass (pull to refresh, a follow or unfollow, the next launch
/// out of Low Power Mode) picks them up. A feed playback needs is fetched on demand by `FollowedSourceCoordinator.audio`,
/// not by this pass.
public enum FeedRefreshScope: Equatable, Sendable {
    case allFeeds
    case firstScreen

    /// How many of Following's rows fit on the first screen of a phone.
    public static let firstScreenShowCount = 10

    public static func atLaunch(lowPowerMode: Bool) -> FeedRefreshScope {
        lowPowerMode ? .firstScreen : .allFeeds
    }

    /// The subscription ids this scope covers; nil means every feed. The first screen is Following's own order (the
    /// show with the newest episode first, Quiet shows below), read from the same rule that builds its rows.
    public func subscriptionIDs(subscriptions: [FeedSubscription], entries: [FeedEntry]) -> Set<String>? {
        switch self {
        case .allFeeds:
            return nil
        case .firstScreen:
            let rows = FollowingShowRows.build(subscriptions: subscriptions, entries: entries).rows
            return Set(rows.prefix(Self.firstScreenShowCount).map(\.id))
        }
    }
}
