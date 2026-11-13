import Foundation

/// Whether the listener has finished an item: the one rule the Library, Following and audio preparation read (#4178).
///
/// An item is finished when the listener marked it finished (`sourceCompletedAt`) or played it to the end
/// (`PreparationChunkGate.itemAlreadyListened`). Adding the item again (`Item.addedAgainAt`) starts it over: a share,
/// the Safari extension or a link that lands on an item already in the Library, or in Recently Deleted, clears the mark
/// and leaves out the listening that ended before it. Before this rule, sharing an article heard last week brought back
/// the old finished copy, which the Library's default "Unfinished" view hid while the app said "Added to Library".
///
/// Every caller that asks "is this item finished?" asks here, so no surface can count the old listening again.
public enum ItemFinishedRule {
    public static func isFinished(_ item: some LibraryItemFields, sessions: [Session]) -> Bool {
        item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(countedSessions(item, sessions: sessions))
    }

    /// The item's sessions that still count: all of them, unless the listener added the item again, and then only
    /// those with listening after that. A finished session's listening ended when it finished: Continue never resumes
    /// one, but the engine saves it once more as it closes, which moves its `updatedAt` and nothing else. A session with
    /// no timestamps was written by a build older than the re-add field, so it doesn't count once there is one.
    public static func countedSessions(_ item: some LibraryItemFields, sessions: [Session]) -> [Session] {
        guard let addedAgainAt = item.addedAgainAt else { return sessions }
        return sessions.filter { session in
            guard let lastListening = lastListening(of: session) else { return false }
            return lastListening > addedAgainAt
        }
    }

    /// The sessions that still decide the Library row, Continue and the item screen's primary button (#4183). An item
    /// the listener finished and then added again reads as a fresh add, so a session that was finished before the
    /// re-add no longer counts: its row shows no percentage and Continue starts at 0, instead of "100%" and "Replay",
    /// or a resume at 99% that finishes the item again after a few seconds. A session left part way (under 99%, not
    /// finished) keeps its place, so re-sharing an article the listener was 40% through loses nothing.
    ///
    /// Nothing is deleted: the item screen's "Listening sessions" still lists every session as history. An item never
    /// added again returns every session. Where `countedSessions` leaves out a session with no listening time at all,
    /// this treats it as before the re-add: left out when finished, kept when part way.
    public static func continuationSessions(_ item: some LibraryItemFields, sessions: [Session]) -> [Session] {
        continuationSessions(addedAgainAt: item.addedAgainAt, sessions: sessions)
    }

    /// The same rule for a caller that holds the re-add date and not the item (`PlayRule`, the item screen's state).
    public static func continuationSessions(addedAgainAt: Date?, sessions: [Session]) -> [Session] {
        guard let addedAgainAt else { return sessions }
        return sessions.filter { session in
            guard PreparationChunkGate.itemAlreadyListened([session]) else { return true } // part way keeps its place
            guard let lastListening = lastListening(of: session) else { return false }
            return lastListening > addedAgainAt
        }
    }

    private static func lastListening(of session: Session) -> Date? {
        session.completedAt ?? [session.updatedAt, session.createdAt].compactMap({ $0 }).max()
    }

    /// When the Library counts the item as added: the later of its first add and its latest add again, so an item
    /// added again sorts first under Recently Added, as a new one does.
    public static func addedAt(_ item: some LibraryItemFields) -> Date? {
        [item.createdAt, item.addedAgainAt].compactMap { $0 }.max()
    }

    /// Stamps an item the listener just added again: it reads as just added and not finished. Its sessions, Margins
    /// and first-added date are kept.
    public static func addedAgain(_ item: Item, at date: Date = Date()) -> Item {
        var item = item
        item.addedAgainAt = date
        item.sourceCompletedAt = nil
        return item
    }
}
