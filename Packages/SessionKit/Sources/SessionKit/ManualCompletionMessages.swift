import Foundation

/// #1149: what the listener reads when they mark an item complete by hand, take it back, or mark it
/// unfinished, and the Undo that goes with the first.
///
/// These ride the app's shared top banner, which has room for a couple of lines. A podcast title can
/// run to a hundred characters, so the title is shortened here instead of turning the banner into a
/// tall block next to the Undo button.
public enum ManualCompletionMessages {
    /// The most characters of a title a banner shows. "Marked ", the title and " complete." then fit
    /// on two lines beside the button on a phone.
    public static let maxTitleCharacters = 36

    public static let undoTitle = "Undo"

    public static func completed(title: String) -> String {
        let name = shortened(title)
        return name.isEmpty ? "Marked complete." : "Marked \(name) complete."
    }

    public static func undone(title: String) -> String {
        let name = shortened(title)
        return name.isEmpty ? "Undid Mark Complete." : "Undid Mark Complete for \(name)."
    }

    public static func unfinished(title: String) -> String {
        let name = shortened(title)
        return name.isEmpty ? "Marked unfinished." : "Marked \(name) unfinished."
    }

    /// VoiceOver names the whole item with the action, not the shortened title.
    public static func undoAccessibilityLabel(title: String) -> String {
        let name = flattened(title)
        return name.isEmpty ? "Undo Mark Complete" : "Undo Mark Complete, \(name)"
    }

    /// The title on one line, cut at `maxTitleCharacters` with an ellipsis. A cut counts characters as
    /// the listener sees them, so an emoji or an accented letter is never split.
    public static func shortened(_ title: String) -> String {
        let name = flattened(title)
        guard name.count > maxTitleCharacters else { return name }
        return String(name.prefix(maxTitleCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One line: a title with a line break or a run of spaces would make the banner taller.
    private static func flattened(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
