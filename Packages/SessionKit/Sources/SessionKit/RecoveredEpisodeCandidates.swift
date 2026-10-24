import Foundation

extension FeedEntry {
    /// The ids of the Library items that could be this entry's episode when a pending packet is recovered from a
    /// feed (#454), judged from their summaries alone (#2506), in the summaries' order. The audio link names the
    /// episode. A GUID alone does not (some feeds reuse short ones), so it needs the title beside it. A summary has
    /// no GUID, so any item with the same title passes when the entry has a GUID, and the caller loads just those
    /// items to compare the GUID. Never leaves out an item the full rule keeps.
    public func recoveryCandidateItemIDs(among summaries: [LibraryItemSummary]) -> [String] {
        let wantedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return summaries.filter { summary in
            if let audioURL, summary.media?.url == audioURL { return true }
            guard episodeGUID != nil else { return false }
            return summary.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wantedTitle
        }.map(\.id)
    }
}
