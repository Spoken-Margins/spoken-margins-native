import Foundation

/// Changing a live session's details while it runs (#2832): starting is one tap with blanks allowed, so the kind, the
/// name, the source clock and the chapter or page are all settable afterwards.
///
/// Every field is one the session already stores, so a session saved by this build reads in an earlier one unchanged.
/// Moving the source clock moves it for the whole session, existing Margins included: the original start position
/// was the listener's estimate, and a correction to it applies to every Margin that estimate placed. A Margin whose
/// position the listener slid by hand (`listenerPositionMs`) keeps that position.
public enum LiveSessionEdit {
    public enum Failure: Error, Equatable, LocalizedError {
        case clockBeforeStart(sessionTime: String)

        public var errorDescription: String? {
            switch self {
            case let .clockBeforeStart(sessionTime):
                "The clock can't be earlier than the \(sessionTime) since you tapped Start. Enter where the source is now."
            }
        }
    }

    /// Sets the kind. A paper book has no clock, so changing to one drops the clock; changing to a meeting from a kind
    /// with no clock starts the meeting clock at the moment the session began, as starting a meeting does.
    public static func setKind(_ kind: ElsewhereKind, on session: inout LiveSession) {
        guard session.kind != kind else { return }
        session.kind = kind
        if kind == .paper {
            session.startPositionMs = nil
            session.endPositionMs = nil
        } else if kind == .meeting, session.startPositionMs == nil {
            session.startPositionMs = 0
        }
    }

    public static func setTitle(_ title: String, on session: inout LiveSession) {
        session.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The chapter or page the session started at. Blank clears it.
    public static func setStartWhere(_ text: String, on session: inout LiveSession) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        session.startWhere = trimmed.isEmpty ? nil : trimmed
    }

    /// Says where the source is at `now`: "the meeting is at 12:30". The clock then runs from there, so the start
    /// position becomes 12:30 minus the time since Start. Throws, changing nothing, when that would put the start
    /// before the source's own beginning (the clock is less than the time since Start), or after the end position.
    public static func setSourceClock(positionMs: Int, at now: Date, on session: inout LiveSession) throws {
        let sinceStartMs = max(0, Int((now.timeIntervalSince(session.startedAt) * 1_000).rounded()))
        let start = positionMs - sinceStartMs
        guard start >= 0 else { throw Failure.clockBeforeStart(sessionTime: LiveSessionPositionMap.clock(sinceStartMs)) }
        try LiveSessionPositionMap.validate(startPositionMs: start, endPositionMs: session.endPositionMs)
        session.startPositionMs = start
    }
}
