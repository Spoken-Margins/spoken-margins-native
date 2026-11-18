import Foundation

/// An episode the listener marked "Show less like this" (#4046). It stops counting as new, isn't ▶'s target and isn't added
/// by "Add everything new", and it feeds the rule learner. Stored as record kind `show_less_mark`, which Build 29 and later
/// shipped builds never read.
public struct ShowLessMark: Codable, Equatable, Sendable, Identifiable {
    /// The entry id when there is one, else the item id, so marking the same episode again, from the Show screen or the Item
    /// screen, replaces one mark instead of adding another.
    public let id: String
    /// `FeedURLKey.make` of the show's feed link.
    public var feedKey: String
    public var entryId: String?
    public var itemId: String?
    /// The episode's title when marked, for the learner (the entry may be gone from the feed by then).
    public var title: String
    public var markedAt: Date

    public init(feedKey: String, entryId: String? = nil, itemId: String? = nil, title: String, markedAt: Date = Date()) {
        self.id = Self.id(entryId: entryId, itemId: itemId)
        self.feedKey = feedKey
        self.entryId = entryId
        self.itemId = itemId
        self.title = title
        self.markedAt = markedAt
    }

    /// The entry id when there is one, else the item id. A blank entry id counts as none.
    public static func id(entryId: String?, itemId: String?) -> String {
        if let entryId, !entryId.isEmpty { return entryId }
        return itemId ?? ""
    }
}
