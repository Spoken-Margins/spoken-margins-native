import Foundation

/// Writes a Margin on an item that isn't the one playing (#1073): the Shortcuts "Add Margin" action given a
/// Library item.
///
/// A Margin belongs to a session, and the player's engine can only write on its current one. Starting the
/// item just to write on it would begin playback from a shortcut. So this builds the Margin with a second
/// engine over the same repository, no audio and no recorder, loaded on the item's saved session. That engine
/// builds the anchor the way it does for a paused session, from the saved place, and nothing it does reaches
/// the transport of whatever is playing. The Margin is an ordinary written Margin, so packets, exports and
/// the notes folder treat it like any other, and no storage changes.
public enum StoredSessionMargin {
    public enum Failure: Error, Equatable {
        case emptyText
        /// The item is gone from the Library, or is in Recently Deleted.
        case itemNotFound
        /// The item has no session to write on, so the listener has not started it yet.
        case noSession
    }

    public struct Saved: Equatable, Sendable {
        public let interjection: Interjection
        public let itemTitle: String
    }

    /// The session a Margin lands on: the item's most recent one the listener could resume, or a finished one
    /// (a recap Margin, #142).
    public static func targetSession(in sessions: [Session]) -> Session? {
        SessionContinuation.preferredContinuationSession(in: sessions)
    }

    public struct ItemChoice: Equatable, Sendable {
        public let id: String
        public let title: String
    }

    /// The Library items a shortcut offers, the one listened to most recently first and then by title. Items in
    /// Recently Deleted are never offered. `startedOnly` leaves out items with no session to write on, which is
    /// what a picker suggests; a lookup by a saved id keeps them so the shortcut can say to start the item first.
    /// A non-empty `query` keeps titles that contain it, ignoring case and accents.
    public static func itemChoices<I: LibraryItemFields>(
        items: [I], sessions: [Session], startedOnly: Bool, matching query: String? = nil
    ) -> [ItemChoice] {
        let sessionsByItem = Dictionary(grouping: sessions, by: \.itemId)
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func lastActivity(_ item: I) -> Date {
            (sessionsByItem[item.id] ?? []).map { $0.updatedAt ?? $0.createdAt ?? .distantPast }.max() ?? .distantPast
        }
        return items
            .filter { item in
                item.deletedAt == nil
                    && (!startedOnly || targetSession(in: sessionsByItem[item.id] ?? []) != nil)
                    && (query.isEmpty || item.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            }
            .sorted { lhs, rhs in
                let (left, right) = (lastActivity(lhs), lastActivity(rhs))
                return left == right ? (lhs.title, lhs.id) < (rhs.title, rhs.id) : left > right
            }
            .map { ItemChoice(id: $0.id, title: $0.title) }
    }

    /// Saves `text` as a written Margin at `itemId`'s saved place. Throws before writing anything when the text
    /// is empty, the item is not in the Library, or it has no session.
    public static func addWritten(
        text: String,
        itemId: String,
        repository: SessionRepository & StructuredDocumentRepository,
        now: @escaping () -> Date = Date.init
    ) throws -> Saved {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyText }
        guard let item = try? repository.loadItem(id: itemId), item.deletedAt == nil else { throw Failure.itemNotFound }
        guard let session = targetSession(in: try repository.loadSessions(itemId: itemId)) else { throw Failure.noSession }

        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "stored-session-margin", displayName: "Stored session Margin", capabilities: [:]),
            repository: repository,
            now: now
        )
        try engine.inspectSession(sessionId: session.id)
        let originalUpdatedAt = session.updatedAt
        let capture = try engine.beginWrittenInterjection()
        do {
            try engine.saveWrittenInterjection(captureId: capture.id, text: text)
        } catch {
            _ = try? engine.cancelWrittenInterjection(captureId: capture.id)
            throw error
        }
        try restoreUpdatedAt(originalUpdatedAt, ofSession: session.id, in: repository)
        let saved = try repository.loadInterjections(sessionId: session.id).first { $0.id == "ij-written-\(capture.id)" }
        guard let saved else { throw SessionKitError.invalidCommandForState("saveWrittenInterjection") }
        return Saved(interjection: saved, itemTitle: item.title)
    }

    /// Saving the Margin stamps the session as touched now. Sessions are ordered by that stamp, and the app
    /// reopens the newest resumable one at launch, so a Margin written from a shortcut must not pull its item
    /// ahead of the one the listener was last listening to.
    private static func restoreUpdatedAt(
        _ updatedAt: Date?, ofSession id: String, in repository: SessionRepository
    ) throws {
        guard var stamped = try repository.loadSession(id: id), stamped.updatedAt != updatedAt else { return }
        stamped.updatedAt = updatedAt
        try repository.saveSession(stamped)
    }
}
