import Foundation

/// #477: what the listener reads when they dismiss a Following entry, and the Undo that goes with it.
///
/// It rides the app's shared top banner, like the Mark Complete Undo (#1149), so the title is
/// shortened the same way to keep the banner at a couple of lines beside the button.
public enum FollowingDismissMessages {
    public static let undoTitle = "Undo"

    public static func dismissed(title: String) -> String {
        let name = ManualCompletionMessages.shortened(title)
        return name.isEmpty ? "Dismissed." : "Dismissed \(name)."
    }

    /// VoiceOver names the whole entry with the action, not the shortened title.
    public static func undoAccessibilityLabel(title: String) -> String {
        let name = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Undo Dismiss" : "Undo Dismiss, \(name)"
    }

    // MARK: Not for me (#4285)

    /// A followed show's episode says "Not for me": it is a verdict the phone keeps, so the episode never comes back,
    /// even after the show is unfollowed and followed again. A Quick Folder file keeps "Dismiss".
    public static let notForMeTitle = "Not for me"
    public static let notForMeSystemImage = "hand.thumbsdown"
    public static let dismissTitle = "Dismiss"
    public static let dismissSystemImage = "xmark"

    /// The row's swipe, menu and VoiceOver action: "Not for me" on a followed show's episode, "Dismiss" on a file.
    public static func actionTitle(isFollowedEntry: Bool) -> String {
        isFollowedEntry ? notForMeTitle : dismissTitle
    }

    public static func actionSystemImage(isFollowedEntry: Bool) -> String {
        isFollowedEntry ? notForMeSystemImage : dismissSystemImage
    }

    /// The banner after Not for me: "Not for me: The Long Article.", shortened like `dismissed(title:)`.
    public static func notForMe(title: String) -> String {
        let name = ManualCompletionMessages.shortened(title)
        return name.isEmpty ? "Not for me." : "Not for me: \(name)."
    }

    /// VoiceOver names the whole entry with the action, not the shortened title.
    public static func notForMeUndoAccessibilityLabel(title: String) -> String {
        let name = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Undo Not for me" : "Undo Not for me, \(name)"
    }

    /// "Clear" on the New list (#1589): one banner, one Undo for all of them.
    public static func cleared(count: Int) -> String {
        "Cleared \(count) \(count == 1 ? "entry" : "entries") from New."
    }

    public static func clearUndoAccessibilityLabel(count: Int) -> String {
        "Undo Clear, \(count) \(count == 1 ? "entry" : "entries")"
    }
}
