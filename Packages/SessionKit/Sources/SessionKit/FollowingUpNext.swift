import Foundation

/// #3863: the episode a followed show offers to hear next, decided once for every surface.
///
/// The Following tab's row previews and plays this episode, and a show's own screen opens with an "Up next"
/// card for it. Both ask `pick`, so the row's ▶ and the card can never name different episodes (#3367, #3691).
/// Pure: the app passes a show's entries and the Library state of the imported ones.
public enum FollowingUpNext {
    /// What the show screen's Up next card needs: the picked entry and the publisher's words about it.
    public struct Card: Equatable, Sendable {
        public var entry: FeedEntry
        /// The publisher's description as plain text (at most `ItemMetadata.descriptionLimit` characters), nil when
        /// the feed gave nothing readable. The card then shows no description block and no placeholder.
        public var description: String?
        /// The episode is in the Library already: the card shows "In your Library" in place of Add.
        public var isInLibrary: Bool
        /// The Library item behind an imported entry, so Play resumes it there. Nil when not in the Library.
        public var libraryItemID: String?
    }

    /// The show's newest episode still worth hearing: not played yet, or in the Library and not finished.
    /// Dismissed entries are never picked. Nil when nothing is left to hear (every episode played or dismissed),
    /// so a heard episode is never featured.
    /// - Parameter entries: the show's entries; entries of other shows are not told apart, so pass one show's.
    public static func pick(
        entries: [FeedEntry], libraryEpisodes: [String: FollowingLibraryEpisode] = [:]
    ) -> FeedEntry? {
        entries
            .filter { $0.state != .dismissed && FollowingShowRows.isHearable($0, libraryEpisodes: libraryEpisodes) }
            .min(by: FollowingShowRows.newestFirst)
    }

    /// The publisher's description of an entry as plain text: its summary, else the opening of its full body.
    /// A writer's feed (Substack) often has no summary, and the body's first lines are the best preview of an article.
    public static func descriptionText(of entry: FeedEntry) -> String? {
        ItemMetadata.plainDescription(from: entry.summary)
            ?? ItemMetadata.plainDescription(from: entry.fullBody.map(withoutHeadingMarks))
    }

    /// A feed body keeps its headings as Markdown heading lines (#4461); a preview shows their words in one flowing line, not the marks.
    private static func withoutHeadingMarks(_ body: String) -> String {
        body.replacingOccurrences(of: #"(?m)^#{1,6}[ \t]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
    }

    /// The Up next card for a show, nil when `pick` finds nothing.
    public static func card(
        entries: [FeedEntry], libraryEpisodes: [String: FollowingLibraryEpisode] = [:]
    ) -> Card? {
        guard let entry = pick(entries: entries, libraryEpisodes: libraryEpisodes) else { return nil }
        let inLibrary = entry.state == .imported
        return Card(
            entry: entry, description: descriptionText(of: entry), isInLibrary: inLibrary,
            libraryItemID: inLibrary ? libraryEpisodes[entry.id]?.itemID : nil)
    }
}
