import Foundation

/// What the Lists screen, a list's own screen and "Add shows to <list>" show (#4046 PR 3), as pure functions over the
/// stored lists and the shows the listener follows, so the screens only draw what this hands them.
///
/// A list's members are feed keys. A member counts as a show here only while it matches a followed show, so a list never
/// shows a row it can't open.
public enum FollowListScreens {
    /// One row of the Lists screen.
    public struct OverviewRow: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// "3 shows" or "1 show".
        public let subtitle: String
        /// VoiceOver reads the name, then the count.
        public var accessibilityLabel: String { "\(name), \(subtitle)" }
    }

    /// One followed show in the "Add shows to <list>" sheet.
    public struct PickerRow: Equatable, Sendable, Identifiable {
        /// The subscription's id.
        public let id: String
        public let title: String
        public let isMember: Bool
    }

    /// The Lists screen's rows, in the order the chips show the lists.
    public static func overviewRows(
        lists: [FollowList],
        subscriptions: [FeedSubscription],
        podcastGUIDs: [String: String] = [:]
    ) -> [OverviewRow] {
        FollowListName.chipOrder(lists).map { list in
            let count = shows(in: list, subscriptions: subscriptions, podcastGUIDs: podcastGUIDs).count
            return OverviewRow(id: list.id, name: list.name, subtitle: FollowListWords.showCount(count))
        }
    }

    /// The followed shows in a list, alphabetical by title (locale-aware, case-insensitive, ties by id). Quiet shows
    /// are in their lists like any other.
    public static func shows(
        in list: FollowList,
        subscriptions: [FeedSubscription],
        podcastGUIDs: [String: String] = [:]
    ) -> [FeedSubscription] {
        alphabetical(subscriptions).filter {
            list.contains(feedKey: FeedURLKey.make($0.source.canonicalURL), podcastGUID: podcastGUIDs[$0.id])
        }
    }

    /// Every followed show, Quiet ones included, alphabetical, each with whether it is in the list.
    public static func pickerRows(
        for list: FollowList,
        subscriptions: [FeedSubscription],
        podcastGUIDs: [String: String] = [:]
    ) -> [PickerRow] {
        alphabetical(subscriptions).map { subscription in
            PickerRow(
                id: subscription.id,
                title: FollowingShowRows.displayTitle(of: subscription),
                isMember: list.contains(feedKey: FeedURLKey.make(subscription.source.canonicalURL), podcastGUID: podcastGUIDs[subscription.id])
            )
        }
    }

    /// How many shows sit in two or more lists. It is the issue's own waste signal: if tags stay at one per show, folders
    /// were enough. A show counts once however many lists hold it, by feed key or by GUID. It holds no names.
    public static func showsInTwoOrMore(_ lists: [FollowList]) -> Int {
        var shows: [ListMember] = []
        var listsHolding: [Set<String>] = []
        for list in lists {
            for member in list.members {
                if let index = shows.firstIndex(where: { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }) {
                    listsHolding[index].insert(list.id)
                } else {
                    shows.append(member)
                    listsHolding.append([list.id])
                }
            }
        }
        return listsHolding.filter { $0.count >= 2 }.count
    }

    private static func alphabetical(_ subscriptions: [FeedSubscription]) -> [FeedSubscription] {
        subscriptions.sorted {
            let order = FollowingShowRows.displayTitle(of: $0).localizedCaseInsensitiveCompare(FollowingShowRows.displayTitle(of: $1))
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}
