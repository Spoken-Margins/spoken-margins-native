import Foundation

/// Ending a live session when it actually stopped, not when the listener got round to tapping End (#2709).
///
/// People end a session after they have stopped: "I stopped reading 15 minutes ago, around page 210". The session's
/// `endedAt` is the time it stopped, because `LiveSessionPositionMap.rate(for:)` divides the distance between the
/// start and end positions by the wall time between them; the tap time would pull every Margin's estimated position
/// the wrong way. The tap time is kept as `endTappedAt` ("ended 14:20, told us at 14:35"), and only when it differs.
///
/// A session saved by an earlier build has no `endTappedAt` and reads as ended at its tap time, and an earlier build
/// reading one of these ignores the extra field.
public enum LiveSessionEnd {
    /// A stopped time within this many seconds of the tap is "now": no second time is kept.
    public static let sameInstant: TimeInterval = 1

    public enum Failure: Error, Equatable, LocalizedError {
        case stoppedBeforeStart
        case stoppedAfterTap

        public var errorDescription: String? {
            switch self {
            case .stoppedBeforeStart: "That time is before the session started. Pick a time after it began."
            case .stoppedAfterTap: "That time hasn't happened yet. Pick a time that has passed."
            }
        }
    }

    /// When the session stopped, as the listener says it: the end sheet's quick choices and its time picker.
    public enum When: Equatable, Sendable {
        case now
        case minutesAgo(Int)
        /// A time of day: the most recent such time at or before the tap, so "23:50" typed at 00:10 is last night.
        case clockTime(hour: Int, minute: Int)

        /// The quick choices on the end sheet, before the time picker.
        public static let quickChoices: [When] = [.now, .minutesAgo(5), .minutesAgo(15), .minutesAgo(30), .minutesAgo(60)]

        public var label: String {
            switch self {
            case .now: "Now"
            case .minutesAgo(60): "1 hour ago"
            case let .minutesAgo(minutes): "\(minutes) minutes ago"
            case let .clockTime(hour, minute): String(format: "At %d:%02d", hour, minute)
            }
        }

        /// The instant this names, given when End was tapped. Nil only for a time of day the calendar can't resolve.
        public func date(tappedAt: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .now:
                return tappedAt
            case let .minutesAgo(minutes):
                return tappedAt.addingTimeInterval(-Double(max(0, minutes)) * 60)
            case let .clockTime(hour, minute):
                var parts = DateComponents()
                parts.hour = hour
                parts.minute = minute
                parts.second = 0
                // Searching backward from just after the tap includes the tap's own minute.
                return calendar.nextDate(after: tappedAt.addingTimeInterval(1), matching: parts, matchingPolicy: .nextTime, direction: .backward)
            }
        }
    }

    /// The quick choices that fall inside the session, so the sheet never offers "1 hour ago" for a session that
    /// began 10 minutes ago.
    public static func quickChoices(startedAt: Date, tappedAt: Date) -> [When] {
        When.quickChoices.filter { choice in
            guard let stopped = choice.date(tappedAt: tappedAt) else { return false }
            return stopped >= startedAt
        }
    }

    /// Rejects a stopped time before the session began or after the tap.
    public static func validate(stoppedAt: Date, startedAt: Date, tappedAt: Date) throws {
        if stoppedAt < startedAt { throw Failure.stoppedBeforeStart }
        if stoppedAt > tappedAt.addingTimeInterval(sameInstant) { throw Failure.stoppedAfterTap }
    }

    /// Ends `session`: it stopped at `when`, the listener told us at `tappedAt`. Margins taken after it stopped but
    /// before the tap are kept and noted "after the session ended". Throws, changing nothing, for a time that can't be.
    public static func end(
        _ session: inout LiveSession, when: When, tappedAt: Date, endPositionMs: Int?, endWhere: String?,
        calendar: Calendar = .current
    ) throws {
        try LiveSessionPositionMap.validate(startPositionMs: session.startPositionMs, endPositionMs: endPositionMs)
        guard var stoppedAt = when.date(tappedAt: tappedAt, calendar: calendar) else { throw Failure.stoppedBeforeStart }
        // A time picked from a clock has no seconds: "this minute" lies up to a minute before the tap and means now.
        if case .clockTime = when, tappedAt.timeIntervalSince(stoppedAt) < 60 { stoppedAt = tappedAt }
        try validate(stoppedAt: stoppedAt, startedAt: session.startedAt, tappedAt: tappedAt)
        let late = tappedAt.timeIntervalSince(stoppedAt) > sameInstant
        session.endedAt = late ? stoppedAt : tappedAt
        session.endTappedAt = late ? tappedAt : nil
        session.endPositionMs = endPositionMs
        session.endWhere = endWhere
        guard late else { return }
        for index in session.margins.indices where session.margins[index].markedAt > stoppedAt {
            session.margins[index].filingNote = session.margins[index].filingNote ?? LiveSessionFiling.afterEndNote
        }
    }
}
