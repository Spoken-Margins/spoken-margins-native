import Foundation

/// The Library item a followed episode became, and whether the listener has finished it. Following's row reads it
/// to preview an episode that is still worth hearing, not one that is done.
public struct FollowingLibraryEpisode: Equatable, Sendable {
    public var itemID: String
    public var isFinished: Bool

    public init(itemID: String, isFinished: Bool) {
        self.itemID = itemID
        self.isFinished = isFinished
    }
}

/// Finds, for each followed episode that is in the Library, the item it became. A feed entry only says `.imported`;
/// whether the listener finished the item lives on the item and its sessions. Pure: the app reads the items,
/// sessions and the import record and passes them in.
public enum FollowingLibraryEpisodes {
    /// - Parameters:
    ///   - entries: every stored entry; only the imported ones can match.
    ///   - items: the Library's items; one in Recently Deleted never matches, so a deleted episode stops counting as saved.
    ///   - importedEntryIds: the record of which entry each imported item came from
    ///     (`ListeningSignalImportedEntries`), which names one entry exactly and wins over a web address.
    /// - Returns: entry id to its item. An imported entry no item matches is absent, as is one whose address
    ///   several imported entries share and nothing narrows (a page that holds several episodes).
    public static func resolve(
        entries: [FeedEntry],
        items: [LibraryItemSummary],
        sessions: [Session],
        importedEntryIds: [String: String] = [:]
    ) -> [String: FollowingLibraryEpisode] {
        let imported = entries.filter { $0.state == .imported }
        guard !imported.isEmpty else { return [:] }
        let importedById = Dictionary(imported.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byAudio: [String: [FeedEntry]] = [:]
        var byPage: [String: [FeedEntry]] = [:]
        for entry in imported {
            if let key = FollowedSourceMatching.normalizedFollowSourceURL(entry.audioURL) { byAudio[key, default: []].append(entry) }
            if let key = FollowedSourceMatching.normalizedFollowSourceURL(entry.canonicalURL) { byPage[key, default: []].append(entry) }
        }
        let sessionsByItem = Dictionary(grouping: sessions, by: \.itemId)

        // Every live copy of an episode that came from one entry. A re-import makes a second copy; the listener
        // may have heard either one, so the row counts the episode as heard if any copy is (#3691).
        var copies: [String: [LibraryItemSummary]] = [:]
        for item in items where item.deletedAt == nil {
            guard let entry = entry(for: item, importedById: importedById, byAudio: byAudio, byPage: byPage,
                                    importedEntryIds: importedEntryIds) else { continue }
            copies[entry.id, default: []].append(item)
        }
        return copies.reduce(into: [:]) { result, pair in
            let (entryId, copiesOfEntry) = pair
            // The later copy is the one the listener has now, so it names the item.
            guard let latest = copiesOfEntry.max(by: { isLater($1, than: $0) }) else { return }
            let entryDurationMs = importedById[entryId]?.audioDurationMs
            result[entryId] = FollowingLibraryEpisode(
                itemID: latest.id,
                isFinished: copiesOfEntry.contains {
                    FollowingHeardRule.isHeard(item: $0, sessions: sessionsByItem[$0.id] ?? [], entryDurationMs: entryDurationMs)
                }
            )
        }
    }

    private static func entry(
        for item: LibraryItemSummary,
        importedById: [String: FeedEntry],
        byAudio: [String: [FeedEntry]],
        byPage: [String: [FeedEntry]],
        importedEntryIds: [String: String]
    ) -> FeedEntry? {
        if let id = importedEntryIds[ListeningSignalImportedEntries.itemKey(item.id)], let entry = importedById[id] { return entry }
        let keys = Set([item.externalReference, item.media?.url].compactMap(FollowedSourceMatching.normalizedFollowSourceURL))
        // An audio address names one episode; a page address may be shared, so it decides only when it is unique.
        for index in [byAudio, byPage] {
            let found = Set(keys.flatMap { index[$0] ?? [] }.map(\.id))
            if found.count == 1, let id = found.first { return importedById[id] }
            if found.count > 1 { return nil }
        }
        return nil
    }

    private static func isLater(_ item: LibraryItemSummary, than other: LibraryItemSummary) -> Bool {
        let (a, b) = (item.createdAt ?? .distantPast, other.createdAt ?? .distantPast)
        return a != b ? a > b : item.id > other.id
    }
}
