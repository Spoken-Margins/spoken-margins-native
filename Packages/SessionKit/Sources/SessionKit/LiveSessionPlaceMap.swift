import Foundation

extension LiveSession {
    /// The unit this session's positions are in (#2707): the clock when it has one, else the unit of the page, percent
    /// or chapter the listener gave for the start or end. Nil when the listener gave no position at all. A paper book
    /// has no clock, even if the session had one before the listener changed its kind (#2832).
    public var positionUnit: LiveSessionPlace.Unit? {
        if kind != .paper, startPositionMs != nil { return .time }
        return startPlace?.unit ?? endPlace?.unit
    }

    /// True when Margins are placed by page, percent or chapter and not by a clock: so a time must never be shown for
    /// one. A paper book always is, whether or not the listener has given a page yet.
    public var usesPlaces: Bool {
        if kind == .paper { return true }
        return positionUnit.map { $0 != .time } ?? false
    }

    /// Keeps the place heard in a Margin's words as that Margin's checkpoint. False when there is none to keep.
    @discardableResult
    public mutating func keepHeardPlace(forMarginId id: String) -> Bool {
        guard let index = margins.firstIndex(where: { $0.id == id }), let heard = margins[index].heardPlace else { return false }
        margins[index].place = heard
        margins[index].declinedHeardPlace = nil
        return true
    }

    /// Turns down the place heard in a Margin's words, so it isn't offered again.
    @discardableResult
    public mutating func declineHeardPlace(forMarginId id: String) -> Bool {
        guard let index = margins.firstIndex(where: { $0.id == id }), margins[index].heardPlace != nil else { return false }
        margins[index].declinedHeardPlace = true
        return true
    }
}

extension LiveSessionMargin {
    /// A page, percent or chapter said in this Margin's words ("I'm on page 118"), offered to the listener as a
    /// checkpoint with one tap to keep it (DESIGN section 2, point 4). Nil once they have kept one, set one by typing,
    /// or turned it down.
    public var heardPlace: LiveSessionPlace? {
        guard place == nil, declinedHeardPlace != true else { return nil }
        return LiveSessionPlace.hear(in: text)
    }
}

/// Where a Margin falls when a session is placed by page, percent or chapter (#2707), the same way
/// `LiveSessionPositionMap` places one by a clock.
///
/// A Margin's own place (typed in it, or said in it and kept) is the answer in the unit the listener used. Otherwise
/// the place is worked out between the two checkpoints on either side of it, in the same unit: page 100 at the start
/// and page 140 at the end, a Margin halfway through is "about page 120". Checkpoints are the session's start and end
/// places and every other Margin's kept place. Between units there is no guessing: a page is never turned into a
/// percent or a time, and a Margin with no checkpoint on one side of it has no estimate.
public enum LiveSessionPlaceMap {
    public enum Failure: Error, Equatable, LocalizedError {
        case endBeforeStart(LiveSessionPlace.Unit)

        public var errorDescription: String? {
            switch self {
            case let .endBeforeStart(unit):
                "The \(unit.noun) you stopped at is before the \(unit.noun) you started at. Check where you were when you started and stopped."
            }
        }
    }

    /// Rejects an end place before the start place in the same unit. Places in different units can't be compared and
    /// are accepted.
    public static func validate(start: LiveSessionPlace?, end: LiveSessionPlace?) throws {
        if let start, let end, start.unit == end.unit, end.value < start.value { throw Failure.endBeforeStart(start.unit) }
    }

    public struct Checkpoint: Equatable, Sendable {
        public enum Source: Int, Sendable { case start, margin, end }

        public var wallTime: Date
        public var place: LiveSessionPlace
        public var source: Source
        public var marginId: String?
    }

    /// The session's checkpoints in one unit, in time order.
    public static func checkpoints(in session: LiveSession, unit: LiveSessionPlace.Unit, excluding marginId: String? = nil) -> [Checkpoint] {
        var points: [Checkpoint] = []
        if let place = session.startPlace, place.unit == unit {
            points.append(Checkpoint(wallTime: session.startedAt, place: place, source: .start, marginId: nil))
        }
        for margin in session.margins where margin.id != marginId {
            if let place = margin.place, place.unit == unit {
                points.append(Checkpoint(wallTime: margin.markedAt, place: place, source: .margin, marginId: margin.id))
            }
        }
        if let place = session.endPlace, place.unit == unit, let endedAt = session.endedAt {
            points.append(Checkpoint(wallTime: endedAt, place: place, source: .end, marginId: nil))
        }
        return points.enumerated()
            .sorted { ($0.element.wallTime, $0.element.source.rawValue, $0.offset) < ($1.element.wallTime, $1.element.source.rawValue, $1.offset) }
            .map(\.element)
    }

    public struct Located: Equatable, Sendable {
        public enum Basis: Equatable, Sendable {
            /// The listener's own words, in their unit.
            case said
            /// Worked out between two checkpoints.
            case estimate
        }

        public var place: LiveSessionPlace
        public var basis: Basis

        /// "page 118", or "about page 120" for an estimate.
        public var label: String { (basis == .estimate ? "about " : "") + place.label }
        public var sentenceLabel: String { label.prefix(1).uppercased() + label.dropFirst() }
    }

    /// The Margin's place when the session is placed by page, percent or chapter. Nil for a session with a clock
    /// (`LiveSessionPositionMap` places those) and when nothing says where the Margin is.
    public static func located(_ margin: LiveSessionMargin, in session: LiveSession) -> Located? {
        let unit = session.positionUnit
        if unit == .time { return nil }
        if let said = margin.place, unit == nil || said.unit == unit { return Located(place: said, basis: .said) }
        guard let unit else { return nil }
        return estimate(at: margin.markedAt, unit: unit, in: session, excluding: margin.id)
    }

    /// "page 118", "about page 120", or nil: the text for a Margin in a session placed by place. Nil as well for a
    /// session with a clock, whose callers use the clock.
    public static func label(for margin: LiveSessionMargin, in session: LiveSession) -> String? {
        located(margin, in: session)?.label
    }

    /// The place at `wallTime`, between the checkpoints on either side of it. Nil with no checkpoint before it, or
    /// none after it (except the session's own end), or when the two disagree (the later one is an earlier place).
    public static func estimate(at wallTime: Date, unit: LiveSessionPlace.Unit, in session: LiveSession, excluding marginId: String? = nil) -> Located? {
        let points = checkpoints(in: session, unit: unit, excluding: marginId)
        guard let lowerIndex = points.lastIndex(where: { $0.wallTime <= wallTime }) else { return nil }
        let lower = points[lowerIndex]
        guard lowerIndex + 1 < points.count else {
            return lower.source == .end ? Located(place: lower.place, basis: .estimate) : nil
        }
        let upper = points[lowerIndex + 1]
        guard upper.place.value >= lower.place.value else { return nil }
        let fraction = wallTime.timeIntervalSince(lower.wallTime) / upper.wallTime.timeIntervalSince(lower.wallTime)
        let raw = lower.place.value + fraction * (upper.place.value - lower.place.value)
        // A page rounds to the nearest page, a percent to the nearest percent, and a chapter is the one it has reached.
        let value: Double = unit == .chapter ? raw.rounded(.down) : raw.rounded()
        return LiveSessionPlace(unit: unit, value: value).map { Located(place: $0, basis: .estimate) }
    }

    // MARK: Checkpoints that disagree

    /// Two checkpoints in the same unit where the later one is an earlier place: "page 150 at 10:10, page 140 at
    /// 10:40". Either could be the typo, so neither is chosen; an estimate between them is left out and the export says so.
    public struct Conflict: Equatable, Sendable {
        public var earlier: Checkpoint
        public var later: Checkpoint

        public func description(timeZone: TimeZone = .current) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            return "You gave \(earlier.place.label) at \(formatter.string(from: earlier.wallTime)) and \(later.place.label) at "
                + "\(formatter.string(from: later.wallTime)). That goes backwards, so check one of them."
        }
    }

    public static func conflicts(in session: LiveSession) -> [Conflict] {
        var found: [Conflict] = []
        for unit in LiveSessionPlace.Unit.allCases where unit != .time {
            let points = checkpoints(in: session, unit: unit)
            for (earlier, later) in zip(points, points.dropFirst()) where later.place.value < earlier.place.value {
                found.append(Conflict(earlier: earlier, later: later))
            }
        }
        return found
    }

    // MARK: A meeting's clock

    /// A meeting's clock at the end, set against the clock typed at the start (#2707 owner discussion, 2026-10-26). A
    /// call's timer runs in real time, so the clock at the end minus the time since Start is what it read at Start,
    /// whatever was typed: someone who joined late and left the start blank typed 0:00. When the two differ by more
    /// than a minute the session says so; it does not pick one silently.
    public struct ClockCheck: Equatable, Sendable {
        public var typedStartMs: Int
        public var impliedStartMs: Int
        public var endMs: Int
        public var wallMs: Int

        /// A negative implied start is a call that had not begun its own clock when Start was tapped.
        public var note: String {
            let implied = impliedStartMs < 0
                ? "before its own clock began"
                : LiveSessionPositionMap.clock(impliedStartMs)
            return "You gave \(LiveSessionPositionMap.clock(typedStartMs)) at the start, but the clock showed "
                + "\(LiveSessionPositionMap.clock(endMs)) after \(LiveSessionPositionMap.clock(wallMs)), "
                + "which puts the start at \(implied). Margins are placed between the two you gave."
        }
    }

    public static let clockCheckToleranceMs = 60_000

    public static func clockCheck(for session: LiveSession) -> ClockCheck? {
        // Ended late (told us after it stopped), the clock may have been read at either time: no check.
        guard session.kind == .meeting, session.endTappedAt == nil, let start = session.startPositionMs,
              let end = session.endPositionMs, let endedAt = session.endedAt else { return nil }
        let wallMs = Int((endedAt.timeIntervalSince(session.startedAt) * 1_000).rounded())
        guard wallMs > 0 else { return nil }
        let implied = end - wallMs
        guard abs(implied - start) > clockCheckToleranceMs else { return nil }
        return ClockCheck(typedStartMs: start, impliedStartMs: implied, endMs: end, wallMs: wallMs)
    }
}
