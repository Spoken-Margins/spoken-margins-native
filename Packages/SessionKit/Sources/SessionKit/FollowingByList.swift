import Foundation

/// What Following shows under a list chip (#4046 PR 2), apart from the screen so it can be host-tested. With **All**
/// selected, nothing here changes a row: the screen is exactly what it was without lists (J13).
public enum FollowingByList {
    public struct Screen: Equatable, Sendable {
        /// The rows above the Quiet group, in the order `FollowingFeed` gave them.
        public var rows: [FollowingFeed.Row]
        public var quiet: [FollowingShowRow]
        /// "Every show in <list> is Quiet." Set when the list has Quiet shows and nothing else. The Quiet group then
        /// starts open.
        public var allQuietNote: String?
        /// "No shows in <list> yet". Set when nothing in the list is followed; the screen puts **Add shows** under it.
        public var emptyListText: String?

        public var opensQuietGroup: Bool { allQuietNote != nil }
    }

    /// The selection that still means something: nil (All) when the list was deleted or never loaded.
    public static func resolvedSelection(_ selected: String?, in lists: [FollowList]) -> String? {
        guard let selected, lists.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }

    /// - Parameters:
    ///   - selected: the chosen list's id, or nil for **All**.
    ///   - lists: the stored lists. Until they have loaded this is empty, which shows **All** with no chips, never a
    ///     half-filtered list.
    ///   - feedRows: Following's rows, friends and shows together (`FollowingFeed.visibleRows`).
    ///   - shows: the show rows and the Quiet rows the same rows were built from.
    ///   - subscriptions: resolves a row to its feed link.
    ///   - podcastGUIDs: a subscription's podcast GUID by subscription id, where known (none stored yet).
    public static func screen(
        selected: String?,
        lists: [FollowList],
        feedRows: [FollowingFeed.Row],
        shows: FollowingShowList,
        subscriptions: [FeedSubscription],
        podcastGUIDs: [String: String] = [:]
    ) -> Screen {
        guard let id = resolvedSelection(selected, in: lists), let list = lists.first(where: { $0.id == id }) else {
            return Screen(rows: feedRows, quiet: shows.quiet, allQuietNote: nil, emptyListText: nil)
        }
        let inList = FollowListFilter.apply(
            rows: shows.rows, quietRows: shows.quiet, list: list, subscriptions: subscriptions, podcastGUIDs: podcastGUIDs
        )
        let keptIDs = Set(inList.rows.map(\.id))
        // Friend rows are hidden under a chip; a show keeps the place `FollowingFeed` gave it.
        let rows = feedRows.filter { row in
            if case .show(let show) = row { return keptIDs.contains(show.id) }
            return false
        }
        let nothingLoaded = inList.rows.isEmpty && inList.quiet.isEmpty
        return Screen(
            rows: rows,
            quiet: inList.quiet,
            allQuietNote: inList.rows.isEmpty && !inList.quiet.isEmpty ? FollowListWords.allQuietNote(listName: list.name) : nil,
            emptyListText: nothingLoaded ? FollowListWords.emptyListText(listName: list.name) : nil
        )
    }
}
