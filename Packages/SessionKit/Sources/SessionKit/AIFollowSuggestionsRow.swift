import Foundation

/// Following's "Suggested by your AI" row (#4683, Design section 2h): what it says, and which suggestions a closed
/// follow preview has settled. Pure, so the words and the removal rule are host-tested; the screen only draws them.
public struct AIFollowSuggestionsRow: Equatable, Sendable {
    public static let title = "Suggested by your AI"
    public static let accessibilityHint = "Opens a preview. Nothing is followed until you tap Follow."
    /// Shown when the row is tapped while the follow preview is still following an earlier list.
    public static let stillFollowingMessage = "Still following the last shows. Try again in a moment."

    /// Line two: "2 shows · Morning brief, November 23", or "2 shows" when the newest list had no title.
    public let detail: String
    /// "Suggested by your AI, 2 shows, from Morning brief, November 23".
    public let accessibilityLabel: String
    /// The feed links the preview opens with, oldest first.
    public let feedLinks: [String]

    /// The row for these suggestions, which the caller has already filtered against current follows
    /// (`AIFollowSuggestions.pending(excluding:)`). Nil when none is pending, so the row is not drawn.
    public static func make(pending: [AIFollowSuggestions.Suggestion]) -> AIFollowSuggestionsRow? {
        guard !pending.isEmpty else { return nil }
        let count = pending.count == 1 ? "1 show" : "\(pending.count) shows"
        let listTitle = AIFollowSuggestions.newestListTitle(in: pending)
            .map { $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return AIFollowSuggestionsRow(
            detail: listTitle.map { "\(count) · \($0)" } ?? count,
            accessibilityLabel: listTitle.map { "\(title), \(count), from \($0)" } ?? "\(title), \(count)",
            feedLinks: pending.map(\.url)
        )
    }

    /// The links a closed preview settled, which leave the suggestions: those it followed, and those it did not offer to
    /// follow (already followed, or not a feed link the preview can use). A link it offered and the listener left
    /// unticked, or that failed or was stopped before, stays for next time. Matched by `FeedURLKey`, since the preview
    /// rewrites an http feed to https.
    ///
    /// - Parameters:
    ///   - passed: the links the preview was opened with.
    ///   - offered: the feed links of the preview's New rows, or empty when it could not read the list at all.
    ///   - followed: the feed links it followed.
    public static func settled(passed: [String], offered: [String], followed: [String]) -> [String] {
        let offeredKeys = Set(offered.compactMap(FeedURLKey.make))
        let followedKeys = Set(followed.compactMap(FeedURLKey.make))
        return passed.filter { url in
            guard let key = FeedURLKey.make(url) else { return true }
            return !offeredKeys.contains(key) || followedKeys.contains(key)
        }
    }
}
