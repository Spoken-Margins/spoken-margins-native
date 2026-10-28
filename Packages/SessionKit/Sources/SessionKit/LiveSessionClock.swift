import Foundation

/// The running clock of the thing the listener is taking Margins on (#2834): the meeting's own elapsed time, the
/// audiobook app's time. It is the session's wall clock shifted by the start position the listener gave, so it reads
/// "12:30 in the meeting" while the session counter reads how long ago they tapped Start.
public enum LiveSessionClock {
    /// What the clock is called for this kind. Nil for a paper book, which has no clock.
    public static func title(for kind: ElsewhereKind) -> String? {
        switch kind {
        case .meeting: "Meeting clock"
        case .audiobook: "Audiobook time"
        case .other: "Source time"
        case .paper: nil
        }
    }

    /// The moment the source's clock read 0:00, so `Text(origin, style: .timer)` counts the source's own time.
    /// Nil when the session has no clock: a paper book, or no start position given. Also nil while the source's clock
    /// has not begun yet (Start tapped in the lobby): a timer counts down to a moment in the future, but the screen
    /// holds at 0:00, so both wait for it (`beginsAt`).
    public static func origin(of session: LiveSession, now: Date) -> Date? {
        guard let origin = rawOrigin(of: session), origin <= now else { return nil }
        return origin
    }

    /// When the source's clock begins, if that is still ahead: the moment to look again.
    public static func beginsAt(_ session: LiveSession, now: Date) -> Date? {
        guard let origin = rawOrigin(of: session), origin > now else { return nil }
        return origin
    }

    private static func rawOrigin(of session: LiveSession) -> Date? {
        guard session.kind != .paper, let start = session.startPositionMs else { return nil }
        return session.startedAt.addingTimeInterval(-Double(start) / 1_000)
    }
}
