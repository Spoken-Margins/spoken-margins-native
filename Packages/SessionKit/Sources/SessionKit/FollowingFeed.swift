import Foundation

/// #3343: Following's one list. Friends who sent Margins and followed shows sit together, newest first, instead of
/// every friend above every show. Quiet shows stay in their own section and are not part of this list.
public enum FollowingFeed {
    public enum Row: Identifiable, Equatable, Sendable {
        case friend(FollowingFriends.Friend)
        case show(FollowingShowRow)

        public var id: String {
            switch self {
            case .friend(let friend): "friend::\(friend.id)"
            case .show(let row): "show::\(row.id)"
            }
        }

        /// The one ordering key. A friend's is `Friend.newestAt`; a show's is its previewed episode's date
        /// (`FollowingShowRow.newestEpisodeDate`, the newest episode worth hearing). Nil sorts last.
        public var sortDate: Date? {
            switch self {
            case .friend(let friend): friend.newestAt
            case .show(let row): row.newestEpisodeDate
            }
        }
    }

    /// Splices two lists that are each already newest first (`FollowingFriends.friends`, `FollowingShowRows.build`)
    /// into one. Each list keeps its own order, which carries its tie-breaks; between the lists, the newer date wins
    /// and a tie puts the friend first. Rows with no date follow every dated row.
    public static func rows(friends: [FollowingFriends.Friend], shows: [FollowingShowRow]) -> [Row] {
        var merged: [Row] = []
        merged.reserveCapacity(friends.count + shows.count)
        var f = friends[...]
        var s = shows[...]
        while let friend = f.first, let show = s.first {
            if (friend.newestAt ?? .distantPast) >= (show.newestEpisodeDate ?? .distantPast) {
                merged.append(.friend(friend))
                f = f.dropFirst()
            } else {
                merged.append(.show(show))
                s = s.dropFirst()
            }
        }
        merged += f.map(Row.friend)
        merged += s.map(Row.show)
        return merged
    }

    /// What the screen draws (#3753). Until the show list has loaded once, friends alone would be drawn, and the
    /// shows' newer episodes would then sort above them and push them down: the "snap". So nothing is drawn until
    /// the shows are in, and the first frame is already in its final order.
    public static func visibleRows(friends: [FollowingFriends.Friend], shows: [FollowingShowRow], showsLoaded: Bool) -> [Row] {
        showsLoaded ? rows(friends: friends, shows: shows) : []
    }

    /// Whether to say "You're not following anything yet" (#3753): only when the show list has loaded and there are
    /// really no shows (Quiet ones count) and no friends. Before the load, an empty list means "not read yet".
    public static func showsEmptyState(friends: [FollowingFriends.Friend], shows: FollowingShowList, showsLoaded: Bool) -> Bool {
        showsLoaded && shows.rows.isEmpty && shows.quiet.isEmpty && friends.isEmpty
    }
}
