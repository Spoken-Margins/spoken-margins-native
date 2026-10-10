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
}
