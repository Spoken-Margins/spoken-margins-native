import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// The one way to change a Margin that is already saved: load it by its key, change it and save it whole, in one
    /// transaction (#2509). Another thread's save of the same Margin (the anchor-evidence edits run off the main
    /// thread) then waits for this one instead of landing between the load and the save and being written over by
    /// the stale copy. Nil, with nothing written, when there is no such Margin, or `itemId` is given and differs.
    /// `scripts/tests/test_interjection_writes.py` fails when app code saves a Margin another way.
    @discardableResult
    public func updateInterjection(
        id: String,
        sessionId: String,
        itemId: String? = nil,
        _ mutate: (inout Interjection) throws -> Void
    ) throws -> Interjection? {
        try withSessionTransaction {
            guard var saved = try loadInterjection(id: id, sessionId: sessionId),
                  itemId == nil || saved.itemId == itemId else { return nil }
            try mutate(&saved)
            try saveInterjection(saved)
            return saved
        }
    }
}
