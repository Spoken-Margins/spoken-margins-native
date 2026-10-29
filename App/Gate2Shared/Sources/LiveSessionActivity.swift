import ActivityKit
import AppIntents
import Foundation

/// The live session's Lock Screen Live Activity (#2481): a clock and a Mark button. Compiled into the app and
/// the widget extension. ActivityKit runs the intent in the app's process; it only notes the moment, with no
/// microphone, and the app turns each moment into a blind Margin when the live session screen next reads them.
public struct LiveSessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var markCount: Int
        public var lastMarkAt: Date?
        /// When the source's own clock (the meeting's, the audiobook's) read 0:00, and what that clock is called
        /// (#2834). Optional, so an activity started by an earlier build still decodes: it shows the session counter.
        public var clockOrigin: Date?
        public var clockTitle: String?
        /// Which session this card is for, so a Resume tapped on it reopens that one (#2883). Optional, like the
        /// fields below, so a card started by an earlier build still decodes and reads as running.
        public var sessionId: String?
        /// When the session stopped, once it has ended (#2883): the card then reads "Ended 14:05 · Resume" instead of
        /// a clock. Nil while it runs.
        public var endedAt: Date?
        /// When Resume stops being offered. The card's `staleDate` is the same moment, so the system marks it stale
        /// (`ActivityViewContext.isStale`) and the card drops the button even if the app never runs again.
        public var resumeUntil: Date?

        public init(
            markCount: Int, lastMarkAt: Date? = nil, clockOrigin: Date? = nil, clockTitle: String? = nil,
            sessionId: String? = nil, endedAt: Date? = nil, resumeUntil: Date? = nil
        ) {
            self.markCount = markCount
            self.lastMarkAt = lastMarkAt
            self.clockOrigin = clockOrigin
            self.clockTitle = clockTitle
            self.sessionId = sessionId
            self.endedAt = endedAt
            self.resumeUntil = resumeUntil
        }

        /// True once the session has ended and the card is only waiting out the Resume window.
        public var hasEnded: Bool { endedAt != nil }
    }

    public var sessionStartedAt: Date

    public init(sessionStartedAt: Date) {
        self.sessionStartedAt = sessionStartedAt
    }
}

/// Moments marked from the Lock Screen, waiting for the app to read them. Each Mark is its own key in the
/// App Group (`LiveSessionMarkInbox`), so a Mark written while the screen reads the others is never lost.
public enum LiveSessionMarkQueue {
    private static func inbox() -> LiveSessionMarkInbox? {
        UserDefaults(suiteName: Gate2CompactCommandQueue.appGroupIdentifier).map { LiveSessionMarkInbox(store: $0) }
    }

    @discardableResult
    public static func enqueue(_ date: Date = Date()) -> Bool {
        guard let inbox = inbox() else { return false }
        inbox.enqueue(date)
        return true
    }

    /// Returns the waiting marks and removes exactly those.
    public static func drain() -> [Date] {
        inbox()?.drain() ?? []
    }
}

/// Resumes tapped on the Lock Screen card, waiting for the app (#2883). The tap time is kept: the Resume window is
/// judged then, not when the app next reads it.
public enum LiveSessionResumeQueue {
    /// Posted in the app's process when a Resume is waiting, so a running app applies it at once. When the app was not
    /// running, it applies the request the next time it reads the queue (launch, foreground, the next filing pass).
    public static let requested = Notification.Name("LiveSessionResumeQueue.requested")

    private static func inbox() -> LiveSessionResumeInbox? {
        UserDefaults(suiteName: Gate2CompactCommandQueue.appGroupIdentifier).map { LiveSessionResumeInbox(store: $0) }
    }

    @discardableResult
    public static func enqueue(sessionId: String, at date: Date = Date()) -> Bool {
        guard let inbox = inbox() else { return false }
        inbox.request(sessionId: sessionId, at: date)
        return true
    }

    /// Returns the waiting requests and removes exactly those.
    public static func drain() -> [(sessionId: String, at: Date)] {
        inbox()?.drain() ?? []
    }
}

struct LiveSessionMarkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark This Moment"
    static let description = IntentDescription("Adds a Mark to the live session at this moment, without opening Spoken Margins.")
    static let openAppWhenRun = false

    init() {}

    func perform() async throws -> some IntentResult {
        let now = Date()
        guard LiveSessionMarkQueue.enqueue(now) else { throw LiveSessionMarkError.appGroupUnavailable }
        for activity in Activity<LiveSessionActivityAttributes>.activities {
            var state = activity.content.state
            guard !state.hasEnded else { continue } // an ended card has no Mark button; a late tap changes nothing
            state.markCount += 1
            state.lastMarkAt = now
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        return .result()
    }
}

/// The card's Resume button (#2883). Like the Mark, it runs in the app's process and does the least it can: it notes the
/// tap, shows the card running again at once, and leaves the store to the app (`LiveSessionFileWorker.applyResumes`),
/// which applies the Watch's Resume rules at the tap time. If the rules refuse (another session started), the app
/// removes the card.
struct LiveSessionResumeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Resume Session"
    static let description = IntentDescription("Reopens the live session that just ended, without opening Spoken Margins.")
    static let openAppWhenRun = false

    @Parameter(title: "Session")
    var sessionId: String

    init() {
        sessionId = ""
    }

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func perform() async throws -> some IntentResult {
        let now = Date()
        guard !sessionId.isEmpty, LiveSessionResumeQueue.enqueue(sessionId: sessionId, at: now) else { throw LiveSessionMarkError.appGroupUnavailable }
        for activity in Activity<LiveSessionActivityAttributes>.activities {
            var state = activity.content.state
            guard state.sessionId == sessionId, let until = state.resumeUntil, until >= now else { continue }
            state.endedAt = nil
            state.resumeUntil = nil
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        NotificationCenter.default.post(name: LiveSessionResumeQueue.requested, object: nil)
        return .result()
    }
}

private enum LiveSessionMarkError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "The shared App Group is not configured, so the Lock Screen buttons are unavailable."
    }
}
