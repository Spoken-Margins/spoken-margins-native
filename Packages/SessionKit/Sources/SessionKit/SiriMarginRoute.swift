import Foundation

/// Where a Margin dictated to Siri goes, and the one line Siri says about it (#3880 Design, sections 2 and 5).
/// A pure decision: the first match wins. A Library item chosen in a Shortcut, then a running live session, then
/// the item in the player, then (until slice 2) a refusal. The live session beats the player, as it does for the
/// Watch and the Lock Screen (`LiveSessionFiling`).
public enum SiriMarginRoute: Equatable, Sendable {
    case chosenItem
    case liveSession(name: String)
    case playerItem
    case nothingRunning

    public struct Facts: Equatable, Sendable {
        public var choseItem: Bool
        public var runningSession: LiveSession?
        public var playerHasSession: Bool

        public init(choseItem: Bool, runningSession: LiveSession?, playerHasSession: Bool) {
            self.choseItem = choseItem
            self.runningSession = runningSession
            self.playerHasSession = playerHasSession
        }
    }

    public static func decide(_ facts: Facts) -> SiriMarginRoute {
        if facts.choseItem { return .chosenItem }
        if let session = facts.runningSession { return .liveSession(name: sessionName(session)) }
        if facts.playerHasSession { return .playerItem }
        return .nothingRunning
    }

    /// The session's title, or for an untitled one "your audiobook session" and the like.
    public static func sessionName(_ session: LiveSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty else { return title }
        switch session.kind {
        case .audiobook: return "your audiobook session"
        case .meeting: return "your meeting session"
        case .paper: return "your paper book session"
        case .other: return "your live session"
        }
    }

    /// "Margin added to <name>."
    public static func confirmation(named name: String) -> String {
        "Margin added to \(name)."
    }

    public static let emptyText = "The Margin was empty, so nothing was saved."
    public static let writingInProgress = "You're already writing a Margin in Spoken Margins. Save or cancel it, then ask again."
    public static let nothingRunningMessage = "Nothing is running in Spoken Margins. Start a live session or play something, then ask again."
    public static let notSaved = "Spoken Margins couldn't save the Margin. Ask again."
}
