import Foundation

/// Where a Margin dictated to Siri goes, and the one line Siri says about it (#3880 Design, sections 2 and 5).
/// A pure decision: the first match wins. A Library item chosen in a Shortcut, then a running live session, then
/// the item in the player, then a quick session in the Library (slice 2). The live session beats the player, as it does for the
/// Watch and the Lock Screen (`LiveSessionFiling`).
public enum SiriMarginRoute: Equatable, Sendable {
    case chosenItem
    case liveSession(name: String)
    case playerItem
    case quickSession

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
        return .quickSession
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

    /// What Siri calls the session a Margin went into: a quick session is "a quick session in your Library".
    public static func filedName(_ session: LiveSession) -> String {
        session.isQuick == true ? quickSessionName : sessionName(session)
    }

    public static let quickSessionName = "a quick session in your Library"

    /// "Margin added to <name>."
    public static func confirmation(named name: String) -> String {
        "Margin added to \(name)."
    }

    /// What happened to the screenshot or photo handed to Add Margin or Add Voice Margin (#4925). A picture is never
    /// dropped silently: each outcome other than `.noneGiven` and `.kept` says so in one plain sentence.
    public enum PictureOutcome: Equatable, Sendable {
        /// No picture was given.
        case noneGiven
        /// Kept with the Margin, on this phone.
        case kept
        /// The Margin went to a Library item, which has no place for a picture.
        case notKeptOnItem
        /// The file could not be read as a picture, or it is too large to take.
        case unreadable
        /// The picture was read but could not be stored; the Margin is saved without it.
        case couldNotKeep

        /// The sentence added to Siri's line, nil when no picture was given.
        public var sentence: String? {
            switch self {
            case .noneGiven: nil
            case .kept: "The picture is kept with it on this phone."
            case .notKeptOnItem: "The picture was not kept, because a picture stays only with a Margin in a live session."
            case .unreadable: "The picture could not be read, so it was not kept."
            case .couldNotKeep: "The picture could not be saved, so it was not kept."
            }
        }
    }

    /// "Margin added to <name>." and, when a picture came with it, what became of the picture.
    public static func confirmation(named name: String, picture: PictureOutcome) -> String {
        [confirmation(named: name), picture.sentence].compactMap { $0 }.joined(separator: " ")
    }

    public static let emptyText = "The Margin was empty, so nothing was saved."
    public static let writingInProgress = "You're already writing a Margin in Spoken Margins. Save or cancel it, then ask again."
    /// Only for the narrow case where the player's session ended between the decision and the save: the route itself no
    /// longer refuses (the Margin goes to a quick session).
    public static let nothingRunningMessage = "Nothing is running in Spoken Margins. Start a live session or play something, then ask again."
    public static let notSaved = "Spoken Margins couldn't save the Margin. Ask again."
}
