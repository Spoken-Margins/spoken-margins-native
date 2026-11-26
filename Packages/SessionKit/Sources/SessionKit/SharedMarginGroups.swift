import Foundation

/// The Margins tab's Shared list (#4098, #4105): a friend's Margins grouped by the item they are on, so the listener
/// sees the item first and can open it, instead of one flat run of Margins with no item and no visible order.
///
/// - Groups run by friend activity, newest first: the later of each Margin's recorded time and its packet's import
///   time (`FollowingFriends.activityDate`), so a packet recorded last month and opened today sorts as today. Ties keep
///   the item that appeared first in the input, then the lower item id.
/// - Margins inside a group read in the order the review plays them (`SharedMarginReview`): placed Margins by their time
///   in the listener's copy, then text Margins by character position, then the ones with no place; ties by recorded time
///   and id.
/// - Margins whose item is not in the Library share one last group, whatever its date, so no Margin is dropped and no
///   heading offers a dead link.
public enum SharedMarginGroups {
    public struct Group: Equatable, Sendable {
        /// The Library item, nil for the group of Margins whose item is not in the Library.
        public let itemID: String?
        /// The item's title. For the not-in-Library group, the title its packets carry when they all agree, else nil.
        public let title: String?
        public let entries: [MarginCollection.SharedEntry]
        public let newCount: Int
        /// The first group; the heading's line starts "Newest". The not-in-Library group is never it.
        public let isNewest: Bool
        public let inLibrary: Bool
        public var count: Int { entries.count }
        /// "Newest · 3 Margins · 2 new".
        public var line: String { MarginCountText.itemLine(count, newCount: newCount, isNewest: isNewest) }
    }

    public static func groups(from entries: [MarginCollection.SharedEntry], libraryItemIDs: Set<String>) -> [Group] {
        var inLibrary: [String: [MarginCollection.SharedEntry]] = [:]
        var firstSeen: [String: Int] = [:]
        var newest: [String: Date] = [:]
        var missing: [MarginCollection.SharedEntry] = []
        for (index, entry) in entries.enumerated() {
            guard let itemID = entry.layer.itemId, libraryItemIDs.contains(itemID) else {
                missing.append(entry)
                continue
            }
            inLibrary[itemID, default: []].append(entry)
            if firstSeen[itemID] == nil { firstSeen[itemID] = index }
            newest[itemID] = max(newest[itemID] ?? .distantPast, FollowingFriends.activityDate(entry))
        }
        let order = inLibrary.keys.sorted { lhs, rhs in
            let (l, r) = (newest[lhs]!, newest[rhs]!)
            if l != r { return l > r }
            let (fl, fr) = (firstSeen[lhs]!, firstSeen[rhs]!)
            return fl != fr ? fl < fr : lhs < rhs
        }
        var result = order.enumerated().map { index, itemID -> Group in
            let rows = playOrder(inLibrary[itemID] ?? [])
            return Group(
                itemID: itemID, title: rows.first?.itemTitle, entries: rows, newCount: rows.filter { $0.interjection.showsAsNew }.count,
                isNewest: index == 0, inLibrary: true)
        }
        if !missing.isEmpty {
            let rows = playOrder(missing)
            let titles = Set(rows.map { $0.layer.itemIdentity.title.trimmingCharacters(in: .whitespacesAndNewlines) })
            let shared = titles.count == 1 ? titles.first.flatMap { $0.isEmpty ? nil : $0 } : nil
            result.append(Group(
                itemID: nil, title: shared, entries: rows, newCount: rows.filter { $0.interjection.showsAsNew }.count,
                isNewest: false, inLibrary: false))
        }
        return result
    }

    /// The Mine list's one-row shortcut to friends' unheard Margins (#4105), and the count on the Shared chip.
    public struct NewFromFriends: Equatable, Sendable {
        public let newCount: Int
        public let itemCount: Int
        /// The Library item the row opens: set only when every new Margin is on one item in the Library. Otherwise the
        /// row switches the list to Shared.
        public let itemID: String?
        public let text: String
        public let accessibilityLabel: String
        public var accessibilityHint: String { itemID == nil ? "Shows shared Margins." : "Opens it." }
        /// "2 new" for the capsule on the Shared chip; VoiceOver reads "Shared, 2 new".
        public var chipText: String { "\(newCount) new" }
    }

    /// The unheard Margins among `entries` (the scope's, not narrowed by search), or nil when there are none.
    /// One item: "2 new Margins from Sam · Bill Gates says to prepare…" (the friend line reads "2 new shared Margins"
    /// when the senders are several or unnamed). Several: "5 new Margins from friends on 3 items".
    public static func newFromFriends(_ entries: [MarginCollection.SharedEntry], libraryItemIDs: Set<String>) -> NewFromFriends? {
        let fresh = entries.filter { $0.interjection.showsAsNew }
        guard !fresh.isEmpty else { return nil }
        let keys = Set(fresh.map { entry in entry.layer.itemId.flatMap { libraryItemIDs.contains($0) ? $0 : nil } ?? "" })
        let noun = fresh.count == 1 ? "Margin" : "Margins"
        if keys.count == 1, let only = keys.first, !only.isEmpty {
            let title = fresh[0].itemTitle
            let names = Set(fresh.compactMap { FriendName.usable($0.layer.displayLabel) })
            let allNamed = fresh.allSatisfy { FriendName.usable($0.layer.displayLabel) != nil }
            let friendLine = names.count == 1 && allNamed
                ? "\(fresh.count) new \(noun) from \(names.first!)" : "\(fresh.count) new shared \(noun)"
            return NewFromFriends(
                newCount: fresh.count, itemCount: 1, itemID: only, text: "\(friendLine) · \(title)",
                accessibilityLabel: "\(friendLine), on \(title)")
        }
        let text = "\(fresh.count) new \(noun) from friends on \(keys.count) \(keys.count == 1 ? "episode or article" : "episodes or articles")"
        return NewFromFriends(newCount: fresh.count, itemCount: keys.count, itemID: nil, text: text, accessibilityLabel: text)
    }

    /// One item's Margins in the order the review plays them.
    static func playOrder(_ entries: [MarginCollection.SharedEntry]) -> [MarginCollection.SharedEntry] {
        func key(_ entry: MarginCollection.SharedEntry) -> (rank: Int, position: Int, createdAt: Date, id: String) {
            let margin = entry.interjection
            if let position = SharedMarginPlaybackPosition(margin) { return (0, position.mediaTimeMs, margin.createdAt, margin.id) }
            if let char = margin.anchorEvidence.startChar { return (1, char, margin.createdAt, margin.id) }
            return (2, 0, margin.createdAt, margin.id)
        }
        return entries.sorted { lhs, rhs in
            let (l, r) = (key(lhs), key(rhs))
            if l.rank != r.rank { return l.rank < r.rank }
            if l.position != r.position { return l.position < r.position }
            if l.createdAt != r.createdAt { return l.createdAt < r.createdAt }
            return l.id < r.id
        }
    }
}
