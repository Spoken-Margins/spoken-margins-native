import Foundation

/// The rules for a Margin the listener began on a live session's screen and finishes after the session ended somewhere
/// else (#3847): the Watch's End, or a Watch start that replaced this session, can arrive while the writing screen is open.
/// The Margin is kept in the session on screen rather than dropped; only a session saved to the Library, or gone, takes no
/// more. These are pure, so host tests pin them and the app's controller and views only call them.
public enum LiveSessionBegunMargin {
    /// What to do with a Margin whose writing began on this session's screen.
    public enum Check: Equatable, Sendable {
        /// Keep it. `afterEnd`: the session has ended and the Margin was marked after its stop time, so it carries the
        /// "after the session ended" note.
        case accepted(afterEnd: Bool)
        /// The session is gone or saved to the Library: the Margin is not stored and the draft stays on screen.
        case refused
    }

    /// A Margin begun on this session's screen (the screen opens writing only while the session runs) is kept unless the
    /// session is saved to the Library or gone. There is no time limit: a Watch clock that is off, or an End delivered
    /// late, never refuses a Margin the listener is in the middle of.
    public static func check(markedAt: Date, in session: LiveSession?) -> Check {
        guard let session, session.savedItemId == nil else { return .refused }
        let afterEnd = session.endedAt.map { markedAt > $0 } ?? false
        return .accepted(afterEnd: afterEnd)
    }

    /// `check`, then adds the Margin to the session (one Margin per id, and the first one wins: adding the same id again changes nothing and still reports the check). A Margin marked
    /// after the session's stop time gets the "after the session ended" note unless it already has a filing note.
    /// A refused Margin changes nothing.
    @discardableResult
    public static func add(_ margin: LiveSessionMargin, to session: inout LiveSession) -> Check {
        let result = check(markedAt: margin.markedAt, in: session)
        guard case let .accepted(afterEnd) = result else { return result }
        var kept = margin
        if afterEnd, kept.filingNote == nil { kept.filingNote = LiveSessionFiling.afterEndNote }
        session.add(kept)
        return result
    }

    /// The line the writing screen shows once the session it writes into has ended, or nil while it runs and once it is
    /// saved (a saved session takes no Margins, so the line would promise what Save can't do). The time is when the End was
    /// tapped, in the words the Watch already uses (`WatchContractFormat.timeOfDay`).
    public static func endedLine(for session: LiveSession, timeZone: TimeZone = .current) -> String? {
        guard session.savedItemId == nil, let endedAt = session.endedAt else { return nil }
        let promise = "Saving still adds this Margin to it."
        let at = WatchContractFormat.timeOfDay(session.endHeardAt ?? endedAt, timeZone: timeZone)
        switch session.endReason {
        case LiveSessionWatchSessions.EndReason.watch.rawValue:
            return "This session was ended on your Watch at \(at). \(promise)"
        case LiveSessionWatchSessions.EndReason.replaced.rawValue:
            if let note = session.endNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                return "\(note). \(promise)"
            }
            return "This session ended at \(at). \(promise)"
        default:
            return "This session ended at \(at). \(promise)"
        }
    }

    /// Where a photo goes once the camera returns, or once a photo waits for words.
    public enum AfterPhoto: Equatable, Sendable {
        /// Start the recording with the photo (the session runs and no recording is going).
        case record
        /// Open the writing screen with the photo: the session has ended, and starting the microphone after the listener's
        /// End would record past it.
        case write
        /// The photo can't go anywhere: drop it.
        case discard
    }

    /// A photo taken while a recording is going is dropped (the recording has its own). While the session runs it starts a
    /// recording. After an End it goes to the writing screen if the session still takes the Margin, and is dropped only when
    /// the session is saved or gone.
    public static func afterPhoto(isRunning: Bool, isRecordingSpoken: Bool, photoAt: Date, in session: LiveSession?) -> AfterPhoto {
        if isRecordingSpoken { return .discard }
        // A Watch End can land between the camera tap and the photo coming back: the session says it ended even if the
        // screen's own flag has not caught up yet, and the microphone must not start past the End.
        if isRunning, session?.endedAt == nil { return .record }
        guard session?.endedAt != nil, case .accepted = check(markedAt: photoAt, in: session) else { return .discard }
        return .write
    }
}
