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

        public init(markCount: Int, lastMarkAt: Date? = nil) {
            self.markCount = markCount
            self.lastMarkAt = lastMarkAt
        }
    }

    public var sessionStartedAt: Date

    public init(sessionStartedAt: Date) {
        self.sessionStartedAt = sessionStartedAt
    }
}

/// Moments marked from the Lock Screen, waiting for the app to read them.
public enum LiveSessionMarkQueue {
    private static let storageKey = "LiveSessionMarks.v1"
    private static let maximumBufferedMarks = 500

    private static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: Gate2CompactCommandQueue.appGroupIdentifier)
    }

    @discardableResult
    public static func enqueue(_ date: Date = Date()) -> Bool {
        guard let store = defaults() else { return false }
        var marks = store.array(forKey: storageKey) as? [Double] ?? []
        marks.append(date.timeIntervalSince1970)
        store.set(Array(marks.suffix(maximumBufferedMarks)), forKey: storageKey)
        return true
    }

    /// Returns the waiting marks and clears them.
    public static func drain() -> [Date] {
        guard let store = defaults() else { return [] }
        let marks = store.array(forKey: storageKey) as? [Double] ?? []
        store.removeObject(forKey: storageKey)
        return marks.map { Date(timeIntervalSince1970: $0) }
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
