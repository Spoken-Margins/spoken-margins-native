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
        })
    }

    /// Friends and the shows that are not Quiet, newest first. Quiet shows stay in `followingShowListCache.quiet`.
    func followingFeedRows(friends: [FollowingFriends.Friend]) -> [FollowingFeed.Row] {
        FollowingFeed.rows(friends: friends, shows: followingShowListCache.rows)
    }

    /// A friend's item as its Library row reads it ("The Show · Podcast · 40%"); nil when the item isn't loaded.
    func followingFriendItemDetail(_ item: FollowingFriends.Friend.Item) -> LibraryRowDetail? {
        libraryItems.first { $0.id == item.id }.map {
            FollowingFriends.itemDetail($0, playbackSpeed: speechPlaybackRateMultiplier)
        }
    }
}
