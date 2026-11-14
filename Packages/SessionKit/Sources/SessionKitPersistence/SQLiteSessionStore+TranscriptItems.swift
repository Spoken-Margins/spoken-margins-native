import Foundation
import SessionKit

/// What `saveTranscriptItem` did with the item.
public struct TranscriptItemSave: Equatable, Sendable {
    /// The item as stored: for an add, the item passed in; for an add again, the item already there, brought back.
    public var item: Item
    /// The item was already in the Library or in Recently Deleted, and has been added again (#4178).
    public var readded: Bool
}

extension SQLiteSessionStore {
    /// Saves a transcript item and its times in one transaction, so no reader sees one without the other (#2997).
    ///
    /// The item's id comes from its text, so the same file always lands on the same row. A new id inserts. An id that
    /// is already there, in the Library or in Recently Deleted, is added again, as `BrowserTextImporter` adds a page
    /// again: the item comes back from Recently Deleted, its finished mark is cleared and it is stamped as added again
    /// at `readdedAt` (`ItemFinishedRule.addedAgain`), unless the listener is still in it (`stillListeningItemIds`), in
    /// which case it is left as it is. The listener's own title, status, first-added date and everything else on the
    /// stored item are kept; only the times are replaced by the new file's.
    @discardableResult
    public func saveTranscriptItem(
        _ item: Item,
        times: TranscriptTimes,
        readdedAt: Date,
        stillListeningItemIds: Set<String> = []
    ) throws -> TranscriptItemSave {
        try withTransaction {
            var stored = item
            var readded = false
            if let existing = try existingItem(id: item.id) {
                readded = true
                stored = existing
                stored.deletedAt = nil
                if !stillListeningItemIds.contains(existing.id) {
                    stored = ItemFinishedRule.addedAgain(stored, at: readdedAt)
                }
            }
            try saveItem(stored)
            try save(kind: TranscriptTimes.recordKind, id: item.id, sessionId: nil, itemId: item.id, value: times)
            return TranscriptItemSave(item: stored, readded: readded)
        }
    }

    /// The item's times, or nil when it has none or this build can't read them.
    public func loadTranscriptTimes(itemId: String) throws -> TranscriptTimes? {
        var payload: String?
        try readTexts("SELECT payload FROM records WHERE kind = ? AND id = ?;", [TranscriptTimes.recordKind, itemId],
                      name: "load_transcript_times") { payload = $0 }
        guard let payload else { return nil }
        return try? decoder.decode(TranscriptTimes.self, from: Data(payload.utf8))
    }

    private func existingItem(id: String) throws -> Item? {
        do { return try loadItem(id: id) }
        catch SessionKitError.missingFixture(let key) where key == "item:\(id)" || key == id { return nil }
    }
}
