import ActivityKit
import Foundation
import SessionKit

/// The live session's Lock Screen card (#2481), kept in step with the session: running with a clock and a Mark
/// button, then after End "Ended 14:05 · Resume" for the Resume window (#2883), then gone.
///
/// An ended card is the same running activity given an ended state and a `staleDate` at the end of the window, not an
/// ended activity: iOS can't update an ended activity, so a Resume tapped on it could never turn it back into the
/// running card. The system marks the card stale when the window closes, so its button goes even if the app never runs
/// again; `endExpired` then removes it whenever the app next runs.
enum LiveSessionActivities {
    typealias State = LiveSessionActivityAttributes.ContentState

    static func runningState(for session: LiveSession, markCount: Int, lastMarkAt: Date?, now: Date = Date()) -> State {
        State(
            markCount: markCount, lastMarkAt: lastMarkAt,
            clockOrigin: LiveSessionClock.origin(of: session, now: now), clockTitle: LiveSessionClock.title(for: session.kind),
            sessionId: session.id
        )
    }

    /// The running card, as a state `current` can change into: its Marks stay, and the ended fields go.
    static func endedState(from current: State, plan: LiveSessionEndedActivity) -> State {
        var state = current
        state.sessionId = plan.sessionId
        state.endedAt = plan.stoppedAt
        state.resumeUntil = plan.resumeUntil
        return state
    }

    /// True for a card that belongs to `sessionId`, or that an earlier build started and so names no session.
    private static func isCard(_ activity: Activity<LiveSessionActivityAttributes>, for sessionId: String) -> Bool {
        activity.content.state.sessionId.map { $0 == sessionId } ?? true
    }

    static func start(for session: LiveSession, markCount: Int = 0) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // An "Ended · Resume" card left from the last session goes: a new session replaces it, and it must not turn
        // into this session's running card on the next update.
        Task {
            for activity in Activity<LiveSessionActivityAttributes>.activities where activity.content.state.hasEnded && !isCard(activity, for: session.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        // The Lock Screen Mark is a convenience; the session works without it.
        _ = try? Activity<LiveSessionActivityAttributes>.request(
            attributes: LiveSessionActivityAttributes(sessionStartedAt: session.startedAt),
            content: ActivityContent(state: runningState(for: session, markCount: markCount, lastMarkAt: nil), staleDate: nil),
            pushType: nil
        )
    }

    /// Shows the running card for `session`: the source's clock (#2834) and the kind follow the session, an ended card
    /// turns back into the running one, and with no card on screen `startIfNone` puts a new one up (a Resume after the
    /// listener swiped the old one away; iOS only allows that while the app is in front).
    static func showRunning(_ session: LiveSession, startIfNone: Bool = false) async {
        let activities = Activity<LiveSessionActivityAttributes>.activities.filter { isCard($0, for: session.id) }
        if activities.isEmpty {
            if startIfNone { start(for: session, markCount: session.margins.filter(\.isBlindMark).count) }
            return
        }
        for activity in activities {
            let current = activity.content.state
            let state = runningState(for: session, markCount: current.markCount, lastMarkAt: current.lastMarkAt)
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Turns the card into "Ended 14:05 · Resume" until the window closes.
    static func showEnded(_ plan: LiveSessionEndedActivity) async {
        for activity in Activity<LiveSessionActivityAttributes>.activities where isCard(activity, for: plan.sessionId) {
            let state = endedState(from: activity.content.state, plan: plan)
            await activity.update(ActivityContent(state: state, staleDate: plan.resumeUntil))
        }
    }

    static func endAll() async {
        for activity in Activity<LiveSessionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Removes the card for `sessionId`; a card from an earlier build, which names none, goes too.
    static func end(sessionId: String) async {
        for activity in Activity<LiveSessionActivityAttributes>.activities where isCard(activity, for: sessionId) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Removes ended cards whose Resume window has closed.
    static func endExpired(now: Date = Date()) async {
        for activity in Activity<LiveSessionActivityAttributes>.activities {
            guard let until = activity.content.state.resumeUntil, until <= now else { continue }
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Resume from anywhere on the phone (#2883): the Lock Screen card, the Live row and the session screen. The rules
/// are the Watch's (`LiveSessionWatchSessions.resume`), applied on the worker; this puts the card, the Library row and
/// the Watch's board right afterwards.
enum LiveSessionResumer {
    static let refusedWords = "This session can't be resumed: more than 10 minutes have passed since you ended it, or another session has started."

    /// Reopens `id` as asked at `at`. Returns the running session, or nil when the rules refuse (the card is removed).
    /// Asking for a session that already runs returns it unchanged.
    @MainActor
    @discardableResult
    static func resume(id: String, at: Date = Date(), files: LiveSessionFileWorker = .shared) async -> LiveSession? {
        let result = await files.applyResumes([.init(sessionId: id, at: at)])
        guard let resumed = result.resumed.first else {
            if let stored = await files.session(id: id), stored.endedAt == nil, stored.savedItemId == nil { return stored }
            await LiveSessionActivities.end(sessionId: id)
            return nil
        }
        await settle(resumed)
        return resumed
    }

    /// The card, the Live row and the Watch after a session ran again.
    @MainActor
    static func settle(_ resumed: LiveSession) async {
        await LiveSessionActivities.showRunning(resumed, startIfNone: true)
        WatchMarginReceiver.shared.processInbox() // the pass sends the Watch its board
        NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
    }
}
