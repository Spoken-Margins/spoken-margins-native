import Foundation

/// What a refresh does with a followed feed's new items (#466): wait in Following for the listener
/// to pick ("Let me pick", the default), or go straight into the Library ("Add every new item").
public enum FeedNewItemPolicy: String, Codable, Equatable, Sendable, CaseIterable {
    case letMePick = "let_me_pick"
    case addEveryNewItem = "add_every_new_item"

    /// The entries a refresh should add to the Library. Only entries first seen in this refresh
    /// qualify: anything the feed already had (the back catalogue at follow time, and imported or
    /// dismissed tombstones) is in `existing`. A feed with no entries yet is a first fetch, so it
    /// adds nothing either.
    public static func entriesToAdd(new refreshed: [FeedEntry], existing: [FeedEntry], policy: FeedNewItemPolicy?) -> [FeedEntry] {
        guard policy == .addEveryNewItem, !existing.isEmpty else { return [] }
        let known = Set(existing.map(\.id))
        var added = Set<String>()
        return refreshed.filter { $0.state == .unseen && !known.contains($0.id) && added.insert($0.id).inserted }
    }
}
