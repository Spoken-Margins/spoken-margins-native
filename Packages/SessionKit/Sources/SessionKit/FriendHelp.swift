import Foundation

/// Help for someone a friend sent Margins to (#5268): the questions a receiver asks, in the receiver's own words, and
/// the app's short answer to each.
///
/// The same questions, in this order, are the `<h2 id>` headings of the site's `Site/friends/index.html`; a test holds
/// the two together. The raw value is the site's anchor and the app's scroll target. The site's answers also cover a
/// browser, so only the questions must match, never the answers.
public enum FriendHelpTopic: String, CaseIterable, Identifiable, Sendable {
    case what
    case app
    case wontOpen = "wont-open"
    case `where`
    case cantHear = "cant-hear"
    case addEpisode = "add-episode"
    case misplaced
    case answer
    case whoHears = "who-hears"
    case remove

    public var id: String { rawValue }

    public var question: String {
        switch self {
        case .what: return "What did my friend send?"
        case .app: return "Do I need the app?"
        case .wontOpen: return "The link or file won't open. What now?"
        case .where: return "Where did my friend's Margins go?"
        case .cantHear: return "Why can't I hear the episode?"
        case .addEpisode: return "Why does it ask me to add the episode or article?"
        case .misplaced: return "Why is a Margin a little off?"
        case .answer: return "How do I answer?"
        case .whoHears: return "Who hears my answer?"
        case .remove: return "How do I get rid of them?"
        }
    }

    public var appAnswer: String {
        switch self {
        case .what:
            return "Margins: short voice or written notes your friend made while listening to an episode or reading an article. "
                + "Each one is pinned to the moment it's about, so you hear it at that point in your own copy."
        case .app:
            return "No. A link plays in any web browser, on a phone or a computer. In Spoken Margins, a link or a .spokenmargins "
                + "file opens the episode or article with your friend's Margins on it, or asks you to add it first."
        case .wontOpen:
            return "A link works for 30 days and has to be copied whole. If it has expired or been cut off, ask your friend to "
                + "share it again. If you're offline, reconnect and try again. If our server had a problem, try again in a minute. "
                + "If links are switched off, ask your friend to send the Margins as a file. If a file is too big, ask for fewer "
                + "Margins at a time. If it needs a newer Spoken Margins, update the app. If the Margins don't match your copy, "
                + "check you have the same edition of the episode or document."
        case .where:
            return "Open the Margins tab and tap Shared. The episode or article is in your Library with a dot until you've heard "
                + "them, even if you finished it before, and your friend has a row on Following. Until you've heard them, its "
                + "screen has a button with your friend's name that plays their Margins."
        case .cantHear:
            return "Your friend sent their Margins, not the episode. Spoken Margins gets the episode from where it's published, "
                + "and sometimes it can't: it was taken down, it's in a private or paid feed, or the connection failed. Your "
                + "friend's Margins still play without it. If it's in a private feed you subscribe to, add it with your own feed link."
        case .addEpisode:
            return "Margins are pinned to moments in your own copy, and the file didn't bring one. Add the same episode, article "
                + "or document to your Library and your friend's Margins land in their places. They wait on that screen until you "
                + "add it or cancel. For a private podcast feed, paste your own feed link and Spoken Margins finds the episode."
        case .misplaced:
            return "Your copy of an episode can differ from your friend's, usually because the ads are different. When it does, "
                + "Spoken Margins says how far off the Margins may be, and a Margin it couldn't place plays after the others. In an "
                + "article, a Margin it couldn't place says so, and you can tap it to listen anyway."
        case .answer:
            return "Tap the record button while their Margin plays, or within 20 seconds after it ends, and your Margin is saved "
                + "as a reply. You can also open their Margin in the Margins tab and tap Reply. Then tap Share to send your "
                + "replies back."
        case .whoHears:
            return "Only the people you send it to. Nothing leaves your phone until you tap Share, and you pick which of your "
                + "Margins go. A link someone sends you is locked with a key that's only in the link: our server can't read it, "
                + "but anyone who has the link can."
        case .remove:
            return "On the episode or article, open About this file on your friend's card and turn their Margins off, or tap "
                + "Hide this Margin on one of them. Where About this file offers it, Hide this sender hides everything from them "
                + "on this phone. Nothing is deleted, and Settings can show them again. For Margins that came by link, you can "
                + "report the link from the menu on the episode or article."
        }
    }

    /// The question a stuck open answers. Every row is a link or file that would not open, so each opens `wontOpen`,
    /// whose answer names each row's next step; the switch is exhaustive so a new row has to choose.
    public static func forOpenFailure(_ content: PacketOpenFailureSheetContent) -> FriendHelpTopic {
        switch content.row {
        case .expired, .unavailable, .cutOff, .linkDamaged, .switchedOff, .serverProblem, .offline, .notAShareLink,
             .fileDamaged, .fileNeedsNewerApp, .fileTooBig, .fileDoesNotMatchLibrary:
            return .wontOpen
        }
    }
}
