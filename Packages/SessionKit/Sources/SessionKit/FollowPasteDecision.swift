import Foundation

/// #3205: what the Follow sheet's Paste control does with the clipboard. A copied show link is followed at once,
/// with no further tap; anything else gets one plain line and follows nothing.
///
/// The link itself is never part of a message: a private feed link carries the listener's token, so it is not
/// repeated back or written to a log.
public enum FollowPasteDecision: Equatable {
    /// Follow this link now. Only `http` and `https` links reach here (a `feed:` link is read as `https`).
    case follow(String)
    /// The clipboard holds no link we can follow.
    case notALink

    public static let notALinkMessage = "The clipboard doesn’t hold a link. Copy a show’s link, then tap Paste."
    public static let sheetTitle = "Follow a show"
    public static let undoTitle = "Undo"

    public static func decide(clipboard: String?) -> FollowPasteDecision {
        guard let text = clipboard?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .notALink }
        guard let link = firstLink(in: text) else { return .notALink }
        return .follow(link)
    }

    /// The first web link in the text, as a string for the follow flow.
    static func firstLink(in text: String) -> String? {
        // `feed://example.com/rss` is a common copy from podcast apps; the feed is served over https.
        for word in text.split(whereSeparator: \.isWhitespace) {
            if let link = normalizedWebURL(String(word)) { return link }
        }
        return nil
    }

    private static func normalizedWebURL(_ word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[],;"))
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let scheme = trimmed[..<colon].lowercased()
        let rest = String(trimmed[trimmed.index(after: colon)...])
        switch scheme {
        case "http", "https":
            guard let host = URL(string: trimmed)?.host, !host.isEmpty else { return nil }
            return trimmed
        case "feed", "feeds":
            // `feed://host/rss` is served over https; `feed:https://host/rss` keeps its inner link.
            if rest.hasPrefix("//") { return normalizedWebURL("https:" + rest) }
            let inner = rest.lowercased()
            return inner.hasPrefix("http://") || inner.hasPrefix("https://") ? normalizedWebURL(rest) : nil
        default:
            return nil
        }
    }

    /// The one line shown after a follow: with an Undo only when the tap added the show.
    public static func followedMessage(showTitle: String?, wasAlreadyFollowed: Bool) -> String {
        let name = ManualCompletionMessages.shortened(showTitle ?? "")
        let shown = name.isEmpty ? "this show" : name
        return wasAlreadyFollowed ? "You already follow \(shown)." : "Following \(shown)."
    }

    public static func undoAccessibilityLabel(showTitle: String?) -> String {
        let name = (showTitle ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Undo Follow" : "Undo Follow, \(name)"
    }
}
