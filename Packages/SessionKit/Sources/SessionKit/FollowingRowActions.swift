import Foundation

/// #478: the words on a Following entry's long-press menu, swipe actions and unfollow confirmation.
/// Every unfollow names the show, so the listener knows which feed is about to go.
public enum FollowingRowActions {
    /// The longest show name a menu title carries before it is cut with an ellipsis.
    public static let maxShowCharacters = 32

    public static let swipeHint = "Swipe a row right to add it, or left to dismiss it. Press and hold for more."

    /// "Unfollow Hard Fork?", or "Unfollow this feed?" when the show has no name.
    public static func unfollowQuestion(showTitle: String?) -> String {
        guard let name = shortened(showTitle) else { return "Unfollow this feed?" }
        return "Unfollow \(name)?"
    }

    /// The menu and swipe button: "Unfollow Hard Fork", or "Unfollow" when the show has no name.
    public static func unfollowTitle(showTitle: String?) -> String {
        guard let name = shortened(showTitle) else { return "Unfollow" }
        return "Unfollow \(name)"
    }

    /// "Mute Hard Fork", or "Mute this show".
    public static func muteTitle(showTitle: String?) -> String {
        guard let name = shortened(showTitle) else { return "Mute this show" }
        return "Mute \(name)"
    }

    /// The name on one line, cut at `maxShowCharacters` the way the listener counts characters, or nil
    /// when it is empty.
    static func shortened(_ title: String?) -> String? {
        guard let title else { return nil }
        let name = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty else { return nil }
        guard name.count > maxShowCharacters else { return name }
        return String(name.prefix(maxShowCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
