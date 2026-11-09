import Foundation

/// The label for a button that sits inside a list row and whose words are the same on every row ("Resume this session",
/// "Details", "Open Margin", "Remove Margin"). VoiceOver reads the label alone when the listener swipes to it, so every
/// row said the same thing and none said which row it belonged to (#3730, sibling of #1919). The label is the action,
/// then a comma, then a short name for the row, so "Details, Why the tide turns" and "Details, Second pass" differ.
public enum RowAccessibilityLabel {
    /// Longest the row's name may be before it is cut at a word, so a long Margin does not make a button read for ten seconds.
    public static let rowNameLimit = 80

    /// `action` alone when no part of the row has any words. Parts are trimmed, runs of whitespace and line breaks become
    /// one space, empty parts are dropped, and the rest are joined with ", ".
    public static func label(_ action: String, row parts: String?...) -> String {
        let name = truncated(parts.compactMap { tidy($0) }.joined(separator: ", "))
        return name.isEmpty ? action : "\(action), \(name)"
    }

    private static func tidy(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func truncated(_ name: String) -> String {
        guard name.count > rowNameLimit else { return name }
        let head = String(name.prefix(rowNameLimit))
        // Cut at the last space so no word is split; one long unbroken word is cut where it is.
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > rowNameLimit / 2 {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }
}
