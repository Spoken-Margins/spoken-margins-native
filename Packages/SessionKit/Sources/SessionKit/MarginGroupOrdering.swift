import Foundation

/// The Margins tab's groups (#1866): Margins stay grouped by item, the groups run newest first by their newest
/// Margin, and the first group is the one labelled "Newest".
public enum MarginGroupOrdering {
    public struct Entry: Equatable, Sendable {
        public let itemID: String
        public let createdAt: Date
        public init(itemID: String, createdAt: Date) {
            self.itemID = itemID
            self.createdAt = createdAt
        }
    }

    public struct Group: Equatable, Sendable {
        public let itemID: String
        public let newestAt: Date
        public let isNewest: Bool
    }

    /// One group per item, ordered by each item's newest Margin, latest first. Ties keep the item that first
    /// appeared earlier in `entries`, then the lower item id, so the order never flickers between refreshes.
    public static func groups(from entries: [Entry]) -> [Group] {
        var newest: [String: Date] = [:]
        var firstSeen: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let existing = newest[entry.itemID] {
                newest[entry.itemID] = max(existing, entry.createdAt)
            } else {
                newest[entry.itemID] = entry.createdAt
            }
            if firstSeen[entry.itemID] == nil { firstSeen[entry.itemID] = index }
        }
        let ordered = newest.keys.sorted { lhs, rhs in
            let (l, r) = (newest[lhs]!, newest[rhs]!)
            if l != r { return l > r }
            let (fl, fr) = (firstSeen[lhs]!, firstSeen[rhs]!)
            return fl != fr ? fl < fr : lhs < rhs
        }
        return ordered.enumerated().map { Group(itemID: $1, newestAt: newest[$1]!, isNewest: $0 == 0) }
    }
}
