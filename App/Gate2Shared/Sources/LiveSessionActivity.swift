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

        public init(markCount: Int, lastMarkAt: Date? = nil, clockOrigin: Date? = nil, clockTitle: String? = nil) {
            self.markCount = markCount
            self.lastMarkAt = lastMarkAt
            self.clockOrigin = clockOrigin
            self.clockTitle = clockTitle
        }
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
            state.markCount += 1
            state.lastMarkAt = now
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        return .result()
    }
}

private enum LiveSessionMarkError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "Marks are unavailable because the shared App Group is not configured."
    }
}
