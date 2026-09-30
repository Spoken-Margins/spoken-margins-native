import Foundation

/// A listener marking an item complete, or unfinished again, by hand (#273). Only the item's
/// `sourceCompletedAt` changes: sessions, positions and listening history are never touched, so an
/// item finished by listening to the end stays finished, and one marked unfinished resumes where it was.
public enum ManualItemCompletion {
    /// Marks the item complete. Returns the item as saved, or nil when it was already marked.
    @discardableResult
    public static func markComplete(itemId: String, at date: Date = Date(), in repository: any SessionRepository) throws -> Item? {
        var item = try repository.loadItem(id: itemId)
        guard item.sourceCompletedAt == nil else { return nil }
        item.sourceCompletedAt = date
        try repository.saveItem(item)
        // The store may round the date; an undo compares against the stored value.
        return try repository.loadItem(id: itemId)
    }

    /// Clears a completion the listener set by hand. With `markedAt` (an undo), only that completion
    /// is cleared, never a later one. Returns the item as saved, or nil when nothing changed.
    @discardableResult
    public static func markUnfinished(itemId: String, markedAt: Date? = nil, in repository: any SessionRepository) throws -> Item? {
        var item = try repository.loadItem(id: itemId)
        guard let completedAt = item.sourceCompletedAt, markedAt == nil || completedAt == markedAt else { return nil }
        item.sourceCompletedAt = nil
        try repository.saveItem(item)
        return item
    }
}
