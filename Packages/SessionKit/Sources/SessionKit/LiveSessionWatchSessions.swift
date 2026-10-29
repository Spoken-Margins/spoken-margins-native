import Foundation

/// What the phone does with sessions the Watch starts, ends and resumes, and the board it sends back (#2487 slice
/// 1b; DESIGN section 2 points 1, 6 and 8, section 4, and defaults 1 and 17). Pure: `LiveSessionFileWorker` gathers
/// the stored sessions and saves what comes back.
///
/// - One named session runs at a time. The later start ends the earlier one at that moment, and the earlier one
///   says so in words ("Lecture ended at 10:20, when you started Meeting on iPhone"), which the Watch shows.
/// - A start is safe to repeat. A session the phone made from a Margin before the start arrived (the file came
///   first) is filled in and runs.
/// - An End from the Watch ends the session, whichever device started it. A late copy of an End from before a
///   Resume is ignored.
/// - Resume reopens the session within ten minutes of its end, unless another named session started since.
/// - The Watch's times are corrected by its measured clock offset; with none, they are used as they are.
public enum LiveSessionWatchSessions {
    /// `LiveSession.endReason`.
    public enum EndReason: String, Sendable {
        /// Ended from the Watch.
        case watch
        /// A later start ended it.
        case replaced
        /// Made from a Watch Margin that named a session the phone hadn't heard of; its start is still to come.
        case placeholder
    }

    /// End notes go to the Watch for this long.
    public static let endNoteKept: TimeInterval = 12 * 60 * 60

    // MARK: Clocks

    /// A time by the Watch's clock, on the phone's clock, with what to say about it (WATCH.md 3.5).
    public static func phoneTime(_ watchTime: Date, clock: WatchClockStamp?) -> (time: Date, note: String?) {
        guard let clock, clock.isFresh(at: watchTime) else { return (watchTime, "Watch clock, not checked") }
        let corrected = watchTime.addingTimeInterval(-clock.offset)
        guard abs(clock.offset) > WatchContract.offsetWorthShowing else { return (corrected, nil) }
        let seconds = String(format: "%.1f", abs(clock.offset))
        return (corrected, "Watch clock \(seconds) s \(clock.offset > 0 ? "ahead" : "behind"), corrected")
    }

    // MARK: Starting, ending, resuming

    /// Applies a start from the Watch. Returns the sessions to save.
    public static func start(
        _ info: WatchSessionInfo, clock: WatchClockStamp?, sessions: [String: LiveSession],
        deletions: LiveSessionFiling.Deletions, now: Date
    ) -> [LiveSession] {
        guard !deletions.deletedSession(info.id) else { return [] }
        let startedAt = phoneTime(info.startedAt, clock: clock).time
        var session: LiveSession
        if let existing = sessions[info.id] {
            guard existing.savedItemId == nil, existing.endReason == EndReason.placeholder.rawValue else { return [] }
            session = existing
            session.startedAt = min(existing.startedAt, startedAt)
            session.endedAt = nil
            session.endTappedAt = nil
            session.endReason = nil
            for index in session.margins.indices {
                session.margins[index].sessionOffsetMs = max(0, Int((session.margins[index].markedAt.timeIntervalSince(session.startedAt) * 1_000).rounded()))
            }
        } else {
            session = LiveSession(id: info.id, kind: .other, startedAt: startedAt)
        }
        session.kind = ElsewhereKind(rawValue: info.kind.rawValue) ?? .other
        session.title = info.title
        session.startPositionMs = info.startPositionMs ?? session.startPositionMs
        session.ownerDevice = WatchDevice.watch.rawValue
        session.isQuick = nil
        return oneRunning(session, among: sessions)
    }

    /// The phone's own new session: the later start ends the earlier one. Returns the other sessions to save, and
    /// the new one, ended, if a session started later already runs.
    public static func phoneStarted(_ session: LiveSession, sessions: [String: LiveSession]) -> [LiveSession] {
        oneRunning(session, among: sessions)
    }

    /// `session` has just started: end whatever named session runs, at the later of the two starts.
    private static func oneRunning(_ session: LiveSession, among sessions: [String: LiveSession]) -> [LiveSession] {
        var started = session
        var changed: [LiveSession] = []
        for other in sessions.values where other.id != session.id && isRunningNamed(other) {
            if other.startedAt <= started.startedAt {
                var ended = other
                ended.endedAt = started.startedAt
                ended.endReason = EndReason.replaced.rawValue
                ended.endNote = endWords(ended, by: started)
                changed.append(ended)
            } else if started.endedAt == nil {
                started.endedAt = other.startedAt
                started.endReason = EndReason.replaced.rawValue
                started.endNote = endWords(started, by: other)
            }
        }
        return [started] + changed.sorted { $0.id < $1.id }
    }

    /// Applies an End from the Watch, at `endedAt` by its clock. Returns the session to save, or none.
    /// `stoppedAt`, when the listener said it stopped earlier (#2709), becomes the session's end and the tap time is kept
    /// beside it, as on the phone; a time before the start or after the tap is brought back inside them.
    public static func end(
        id: String, endedAt: Date, stoppedAt: Date? = nil, clock: WatchClockStamp?, sessions: [String: LiveSession]
    ) -> LiveSession? {
        guard var session = sessions[id], session.savedItemId == nil, session.isQuick != true, session.endedAt == nil else { return nil }
        let end = max(session.startedAt, phoneTime(endedAt, clock: clock).time)
        if let resumed = session.resumedAt, resumed > end { return nil } // an End from before a later Resume
        session.endedAt = end
        if let stoppedAt {
            let stopped = min(end, max(session.startedAt, phoneTime(stoppedAt, clock: clock).time))
            if end.timeIntervalSince(stopped) > LiveSessionEnd.sameInstant {
                session.endedAt = stopped
                session.endTappedAt = end
                LiveSessionEnd.noteLateMargins(in: &session, after: stopped)
            }
        }
        session.endReason = EndReason.watch.rawValue
        session.endNote = nil
        return session
    }

    /// Applies Resume, asked at `at` (the phone's clock). Returns the session to save, or none.
    public static func resume(id: String, at: Date, sessions: [String: LiveSession]) -> LiveSession? {
        guard var session = sessions[id], session.savedItemId == nil, session.isQuick != true,
              let end = session.endedAt, session.endReason != EndReason.placeholder.rawValue else { return nil }
        // The Resume window runs from when End was tapped, not from the earlier time the listener said it stopped.
        let since = at.timeIntervalSince(session.endHeardAt ?? end)
        guard since >= -WatchContract.offsetMaxRoundTrip, since <= WatchContract.resumeWindow else { return nil }
        // Another named session started since it ended: that one is what the listener is doing.
        let startedSince = sessions.values.contains { $0.id != id && $0.isQuick != true && $0.savedItemId == nil && $0.startedAt >= end }
        guard !startedSince else { return nil }
        session.endedAt = nil
        session.endTappedAt = nil
        session.endReason = nil
        session.endNote = nil
        // Running again, the Margins of the gap are inside the session (#2709).
        for index in session.margins.indices where session.margins[index].filingNote == LiveSessionFiling.afterEndNote {
            session.margins[index].filingNote = nil
        }
        session.resumedAt = at
        return session
    }

    // MARK: The board

    /// The phone's view for the Watch.
    public static func board(sessions: [LiveSession], now: Date) -> WatchBoard {
        let running = sessions.filter(isRunningNamed).max { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        var recentlyEnded: LiveSession?
        if running == nil {
            recentlyEnded = sessions
                .filter { session in
                    guard session.isQuick != true, session.savedItemId == nil, let end = session.endHeardAt,
                          session.endReason != EndReason.placeholder.rawValue else { return false }
                    let since = now.timeIntervalSince(end)
                    return since >= 0 && since <= WatchContract.resumeWindow
                }
                .max { ($0.endHeardAt ?? .distantPast, $0.id) < ($1.endHeardAt ?? .distantPast, $1.id) }
        }
        var notes: [String: String] = [:]
        for session in sessions {
            guard let note = session.endNote, let end = session.endHeardAt, now.timeIntervalSince(end) <= endNoteKept else { continue }
            notes[session.id] = note
        }
        return WatchBoard(running: running.map(info), recentlyEnded: recentlyEnded.map(info), endNotes: notes, phoneTime: now)
    }

    /// The Watch counts its Resume window from `endedAt`, so it is sent when the phone heard the End (`endHeardAt`),
    /// not the earlier time the listener said it stopped; that goes in `stoppedAt`, which the Watch shows (#2709).
    public static func info(_ session: LiveSession) -> WatchSessionInfo {
        WatchSessionInfo(
            id: session.id, kind: WatchSessionKind(rawValue: session.kind.rawValue) ?? .other, title: session.title,
            owner: session.ownerDevice == WatchDevice.watch.rawValue ? .watch : .phone,
            startedAt: session.startedAt, startPositionMs: session.startPositionMs, endedAt: session.endHeardAt,
            stoppedAt: session.endTappedAt == nil ? nil : session.endedAt
        )
    }

    // MARK: Helpers

    static func isRunningNamed(_ session: LiveSession) -> Bool {
        session.isQuick != true && session.savedItemId == nil && session.endedAt == nil
    }

    private static func name(_ session: LiveSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? session.kind.label : title
    }

    private static func endWords(_ ended: LiveSession, by later: LiveSession) -> String {
        let device = later.ownerDevice == WatchDevice.watch.rawValue ? "Watch" : "iPhone"
        let at = WatchContractFormat.timeOfDay(later.startedAt)
        return "\(name(ended)) ended at \(at), when you started \(name(later)) on \(device)"
    }
}
