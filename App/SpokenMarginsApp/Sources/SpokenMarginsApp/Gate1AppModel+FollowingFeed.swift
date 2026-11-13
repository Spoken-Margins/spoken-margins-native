import Foundation
import SessionKit

/// What Following's one list reads (#3291, #3343), in one place so the screen and its app test see the same rows.
/// The rules are in SessionKit (`FollowingFriends`, `FollowingShowRows`, `FollowingFeed`, host-tested); this only
/// feeds them the model's current Margins, Library and shows.
extension Gate1AppModel {
    /// The friends who sent Margins, read from the Margins list the app already keeps.
    var followingFriends: [FollowingFriends.Friend] {
        FollowingFriends.friends(from: sharedMarginRows.map {
            MarginCollection.SharedEntry(interjection: $0.interjection, layer: $0.layer, itemTitle: $0.itemTitle)
        }, includeUnnamed: true) // a packet with no usable name is still a row, "A friend" (#4104)
    }

    /// Friends and the shows that are not Quiet, newest first. Quiet shows stay in `followingShowListCache.quiet`.
    /// Empty until the show list has loaded once, so the first frame is already in its final order (#3753).
    func followingFeedRows(friends: [FollowingFriends.Friend]) -> [FollowingFeed.Row] {
        FollowingFeed.visibleRows(friends: friends, shows: followingShowListCache.rows, showsLoaded: followingShowListLoaded)
    }

    /// "You're not following anything yet" shows only once the show list has loaded and there really is nothing (#3753).
    func followingShowsEmptyState(friends: [FollowingFriends.Friend]) -> Bool {
        FollowingFeed.showsEmptyState(friends: friends, shows: followingShowListCache, showsLoaded: followingShowListLoaded)
    }

    /// A friend's item as its Library row reads it ("The Show · Podcast · 40%"); nil when the item isn't loaded.
    func followingFriendItemDetail(_ item: FollowingFriends.Friend.Item) -> LibraryRowDetail? {
        libraryItems.first { $0.id == item.id }.map {
            FollowingFriends.itemDetail($0, playbackSpeed: speechPlaybackRateMultiplier)
        }
    }
}
