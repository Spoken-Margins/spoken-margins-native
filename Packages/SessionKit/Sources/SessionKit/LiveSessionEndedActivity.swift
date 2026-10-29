import Foundation

/// What the Lock Screen card shows after End (#2883): "Ended 14:05 · Resume" for the Resume window, then it goes.
///
/// The card shows when the session stopped (`LiveSession.endedAt`), not when End was tapped, so a session ended late
/// reads the time the listener gave. The window runs from the tap (`LiveSessionWatchSessions.resumableUntil`), the
/// same as the Watch's.
public struct LiveSessionEndedActivity: Equatable, Sendable {
    public var sessionId: String
    /// When it stopped.
    public var stoppedAt: Date
    /// When Resume stops being offered; the card goes then.
    public var resumeUntil: Date

    /// The card for `session` as it ends, or nil when there is nothing to resume (it is saved or a quick session, still
    /// running, or the window has already passed), in which case the card is simply removed.
    public static func plan(for session: LiveSession, now: Date) -> LiveSessionEndedActivity? {
        guard let stoppedAt = session.endedAt,
              let until = LiveSessionWatchSessions.resumableUntil(id: session.id, sessions: [session.id: session]),
              until > now else { return nil }
        return LiveSessionEndedActivity(sessionId: session.id, stoppedAt: stoppedAt, resumeUntil: until)
    }
}
