import Foundation

/// Where "Record a Margin" (the Shortcuts action and Siri phrase that open the app and start a spoken Margin, #4923)
/// puts the recording. A pure decision, first match wins:
/// 1. A Margin is already recording: nothing starts a second one, and nothing fails.
/// 2. A running live session: its spoken Margin starts, as the Live Activity's "Speak a Margin" link does (#2833).
/// 3. The item in the player: the in-app Add a Margin recording starts.
/// 4. Nothing runs: the recording starts at once and is filed into a quick session when it stops (#4927), by the
///    rule a written Margin from Siri follows (`LiveSessionFileWorker.fileWrittenMarginAsQuick`).
///
/// The live session beats the player here as it does for Siri's written Margin (`SiriMarginRoute`), the Watch and the
/// Lock Screen (`LiveSessionFiling`). A chosen Library item has no row: Record a Margin takes no parameters.
public enum RecordMarginRoute: Equatable, Sendable {
    case alreadyRecording
    case liveSession(name: String)
    case playerItem
    case quickSession

    public struct Facts: Equatable, Sendable {
        public var runningSession: LiveSession?
        public var playerHasSession: Bool
        /// A Margin is recording on the phone now: a spoken Margin in a live session, or one on the player's item.
        public var alreadyRecording: Bool

        public init(runningSession: LiveSession?, playerHasSession: Bool, alreadyRecording: Bool) {
            self.runningSession = runningSession
            self.playerHasSession = playerHasSession
            self.alreadyRecording = alreadyRecording
        }
    }

    public static func decide(_ facts: Facts) -> RecordMarginRoute {
        if facts.alreadyRecording { return .alreadyRecording }
        if let session = facts.runningSession { return .liveSession(name: SiriMarginRoute.sessionName(session)) }
        if facts.playerHasSession { return .playerItem }
        return .quickSession
    }

    /// The `margin.record_intent` diagnostic's value for the route.
    public var diagnosticName: String {
        switch self {
        case .alreadyRecording: return "already_recording"
        case .liveSession: return "live_session"
        case .playerItem: return "player_item"
        case .quickSession: return "quick_session"
        }
    }
}
