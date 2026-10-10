import Foundation

/// #479: where Following was scrolled to when the listener opened an entry, so coming back doesn't
/// start again at the top under the feed card.
///
/// Opening an entry replaces the whole root with the Item screen, which destroys Following's list and
/// its scroll state. The root view keeps this value across that switch. It holds the entry at the top
/// of the visible list and the order the list had, so the place can still be found after the entry has
/// been added or dismissed.
public struct FollowingScrollMemory: Equatable, Sendable {
    /// The id of the first entry the listener could see.
    public var topEntryId: String?
    /// The ids of the whole list as it was then, top to bottom.
    public var order: [String]

    public init(topEntryId: String? = nil, order: [String] = []) {
        self.topEntryId = topEntryId
        self.order = order
    }

    /// The first entry of `order` that is on screen, or nil when none is.
    public static func topEntry(visible: Set<String>, order: [String]) -> String? {
        order.first { visible.contains($0) }
    }

    /// The id to scroll to in `current`, or nil to leave the list where it opens.
    ///
    /// The saved entry when it is still listed. When it has gone (added, dismissed, or its show
    /// muted), the nearest entry that was below it and is still listed, then the nearest above it. Nil
    /// when nothing was saved, the list is empty, or none of the saved list survives.
    public func restoreTarget(in current: [String]) -> String? {
        guard let topEntryId, !current.isEmpty else { return nil }
        let present = Set(current)
        if present.contains(topEntryId) { return topEntryId }
        guard let index = order.firstIndex(of: topEntryId) else { return nil }
        if let below = order[(index + 1)...].first(where: present.contains) { return below }
        return order[..<index].last(where: present.contains)
    }
}
