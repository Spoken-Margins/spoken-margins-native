import Foundation

/// The words that go with a `.spokenmargins` file sent as a file (#3800). A file alone reaches a friend without the
/// app as an unknown attachment, so the sender's sheet says the friend needs the app, and Messages and Mail carry one
/// line saying what the file is and where to get the app. The packet and its file name are not touched.
///
/// Only Messages and Mail get the line. `ShareLinkMessage` records that other apps may keep one of two items and drop
/// the other, so a line beside the file could arrive without the file; AirDrop and Files would save the line as a
/// second file. Every other target gets the file alone.
public enum ShareFileMessage {
    /// The activity types that are known to deliver a text and a file together. These are the raw values of
    /// `UIActivity.ActivityType.message` and `.mail`; they are spelled out here so this stays host-testable.
    public static let messageActivityType = "com.apple.UIKit.activity.Message"
    public static let mailActivityType = "com.apple.UIKit.activity.Mail"

    /// A title longer than this is cut, "…" included.
    public static let titleLimit = 80

    public static let needsTheAppSentence = "Your friend needs Spoken Margins to open a file."
    public static let linkOpensAnywhereSentence = "A link opens in any browser."

    /// The caption under the file button. With links on it also says the link route is open to anyone; with links off
    /// there is no link to offer, so it is the first sentence only.
    public static func caption(linksOffered: Bool) -> String {
        caption(linksOffered: linksOffered, repliesOffered: false)
    }

    /// The link sentence when links carry a reply box (#4675, screen A). It leads, since it is what the friend does.
    public static let linkTakesAnswersSentence = "A link opens in any browser, and your friend can answer through it."

    /// The caption with this build's reply boxes in mind. `repliesOffered` is the app's `SM_LINK_REPLIES` setting; it
    /// changes nothing unless links are offered too.
    public static func caption(linksOffered: Bool, repliesOffered: Bool) -> String {
        guard linksOffered else { return needsTheAppSentence }
        return repliesOffered
            ? "\(linkTakesAnswersSentence) \(needsTheAppSentence)"
            : "\(needsTheAppSentence) \(linkOpensAnywhereSentence)"
    }

    /// Whether a share target gets the line beside the file: Messages and Mail only. An unknown or missing type, which
    /// is what an app we have not seen reports, gets the file alone.
    public static func carriesMessage(activityType: String?) -> Bool {
        activityType == messageActivityType || activityType == mailActivityType
    }

    public static func isMail(activityType: String?) -> Bool {
        activityType == mailActivityType
    }

    /// The line beside the file. A blank title leaves out the "on …" part rather than quoting nothing.
    public static func text(itemTitle: String) -> String {
        let join = "Open this file in Spoken Margins. Get it here: \(BetaInviteShare.joinURL)"
        guard let quoted = quotedTitle(itemTitle) else { return "I left you notes. \(join)" }
        return "I left you notes on \(quoted). \(join)"
    }

    /// The Mail subject. Mail's body is `text(itemTitle:)`.
    public static func mailSubject(itemTitle: String) -> String {
        guard let quoted = quotedTitle(itemTitle) else { return "Margins from Spoken Margins" }
        return "Margins on \(quoted)"
    }

    /// The title in curly quotes, or nil for a blank one. Quotes inside the title stay as they are. A title over
    /// `titleLimit` characters (grapheme clusters, not bytes) is cut to the first `titleLimit - 1` and a "…", so the
    /// result, "…" included, is at most `titleLimit` characters.
    static func quotedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let shown = trimmed.count > titleLimit ? String(trimmed.prefix(titleLimit - 1)) + "…" : trimmed
        return "“\(shown)”"
    }
}
