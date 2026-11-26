import Foundation

public enum SessionContinuation {
    public static func isResumableSession(_ session: Session) -> Bool {
        session.status == "in_progress" && session.phase != .abandoned
    }

    public static func preferredContinuationSession(in sessions: [Session]) -> Session? {
        sessions.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            return left == right ? lhs.id < rhs.id : left > right
        }.first { session in
            isResumableSession(session)
                || (session.status == "finished" && session.completionPercent >= ItemFinishedRule.atEndPercent)
        }
    }

    /// Whether Continue picks `session` up where it was left. A finished session isn't: Continue then begins a new
    /// one at the start (the item screen says "Replay"). One rule for `startItem`, the question about Margins the
    /// listener would skip (#474) and the Library row, so they can't disagree about where Continue lands (#4097).
    public static func continueResumes(_ session: Session) -> Bool {
        session.phase != .finished && session.status != "finished" && session.completionPercent < ItemFinishedRule.atEndPercent
    }

    /// Where Continue puts the listener on an item with these sessions, in media milliseconds: the place of the
    /// session it resumes, or 0 when it begins a new one. Nil when Continue resumes a session whose place in the
    /// media isn't known, so the caller must not assume the Margins are ahead.
    public static func continuePlaceMs(sessions: [Session]) -> Int? {
        guard let session = preferredContinuationSession(in: sessions), continueResumes(session) else { return 0 }
        if let mediaTimeMs = session.position.mediaTimeMs { return mediaTimeMs }
        return session.position.charOffset > 0 ? nil : 0
    }

    /// The same for an item the app holds only as a Library row (no sessions in hand, and no store read on the main
    /// thread). The row says whether Continue has a session and how far it is. "Completed" on the row is not enough:
    /// it is true for an item with any session at 99% or more, and Continue still resumes a session below 100%, at
    /// its end (#4097). So only a session at 100% or none means a start from 0; any other is a place the row doesn't
    /// hold, and the caller asks about every new Margin.
    public static func continuePlaceMs(hasContinuationSession: Bool, progressPercent: Int?) -> Int? {
        guard hasContinuationSession else { return 0 }
        return (progressPercent ?? 0) >= ItemFinishedRule.atEndPercent ? 0 : nil
    }
}

extension LibraryItemRow {
    /// Where Continue would put the listener on this item, from the row alone (see `SessionContinuation.continuePlaceMs`).
    public var continuePlaceMs: Int? {
        SessionContinuation.continuePlaceMs(hasContinuationSession: hasContinuationSession, progressPercent: continuationProgressPercent)
    }
}
