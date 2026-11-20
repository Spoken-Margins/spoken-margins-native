import Foundation

/// A listener telling the Library "I'm done with the Margins on this item" without playing each one (#4289).
///
/// Since #4101 a finished item with a friend's new Margins stays in the Library's Unfinished view
/// (`LibraryItemRow.staysInUnfinished`), so a friend's Margins can be found again. The listener who has already dealt
/// with them, by hearing them elsewhere or by choosing not to, had no way to clear the row: Mark Complete does nothing
/// on a finished item, and "new" only ever cleared by playing each Margin. This is that way.
///
/// It only records the same fact playing a Margin records (`firstHeardAt`, once; a later call keeps the first time).
/// No Margin, layer, recording, packet or completion is changed or removed, and the Margins stay listed and playable.
public enum ItemMarginsHeard {
    /// Marks every shared Margin of `itemId` that screens call new (`showsAsNew`) as heard at `date`, and returns how
    /// many it marked. The same Margins the Library counts: a deleted layer, a hidden sender and a hidden Margin are
    /// left alone, so a Margin the listener hid is still new if they bring it back. A Margin nobody can meet on this
    /// phone (#3402) is not counted new, so no "heard" fact is made for it either.
    @discardableResult
    public static func markHeard(
        itemId: String,
        at date: Date = Date(),
        hiding hidden: HiddenSenders = HiddenSenders(),
        in repository: any SessionRepository
    ) throws -> Int {
        var marked = 0
        for layer in try repository.loadImportedCommentaryLayers(itemId: itemId)
        where layer.deletedAt == nil && !hidden.isHidden(layer.senderId) {
            for margin in try repository.loadImportedCommentaryInterjections(layerId: layer.id)
            where margin.showsAsNew && !hidden.isMarginHidden(margin.id) {
                if try repository.markImportedCommentaryInterjectionHeard(id: margin.id, at: date) != nil { marked += 1 }
            }
        }
        return marked
    }
}
