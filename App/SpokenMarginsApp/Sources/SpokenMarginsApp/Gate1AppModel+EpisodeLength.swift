import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence

/// Gives a podcast episode its length before its first play (#4186), so the Library row and the item screen can say it.
/// Two local sources, neither a network call: the downloaded file's own length, and the length a followed show's
/// stored feed entry states. Each only fills a missing length (`fillMissingMediaDuration`), and neither touches the
/// episode that is playing: its length is written by the player, and the engine caches the item.
extension Gate1AppModel {
    /// The id of the item the engine holds, which these fills must leave alone.
    private var currentPlaybackItemId: String? { engine?.currentItem?.id ?? activePlaybackItemId }

    /// A podcast file is ready (a fresh download, a registered file, or, at launch, every downloaded record): read
    /// its length from the file when the item has none. The item's stored length is checked first, off the main
    /// actor, so a file that already has its length is never opened.
    func fillEpisodeLengthFromFile(itemId: String, url: URL, store: SQLiteSessionStore) {
        guard currentPlaybackItemId != itemId else { return }
        Task { [weak self] in
            let needsLength = (try? await StoreReader(store).read { store -> Bool in
                guard let summary = try? store.loadItemSummary(id: itemId) else { return false }
                return EpisodeLengthBackfill.isCandidate(summary)
            }) ?? false
            guard needsLength, let length = await MediaFileLength.read(fileURL: url), !Task.isCancelled,
                  let self, self.currentPlaybackItemId != itemId else { return }
            let filled = (try? await StoreReader(store).read { try $0.fillMissingMediaDuration(itemId: itemId, durationMs: length) }) ?? false
            if filled { self.hangTelemetry.labels.scoped("episodeLength") { self.episodeLengthWasFilled(itemIds: [itemId]) } }
        }
    }

    /// Once per launch, when the first Library rows are published: fill the episodes that have no length from the
    /// feed entries already stored for the shows the listener follows. Reads and writes in one background read; the
    /// pure matcher decides, and it never fetches a feed.
    func backfillStatedEpisodeLengthsOnce(store: SQLiteSessionStore) {
        guard backgroundRefresh.takeEpisodeLengthBackfill() else { return }
        let excluded = currentPlaybackItemId
        Task { [weak self] in
            let filled = (try? await StoreReader(store).read { store -> [String] in
                let summaries = try store.listItemSummaries()
                guard summaries.contains(where: { EpisodeLengthBackfill.isCandidate($0) }) else { return [] }
                let fills = EpisodeLengthBackfill.statedFills(
                    items: summaries, entries: try store.loadFeedEntries(subscriptionId: nil), excludingItemId: excluded)
                var filled: [String] = []
                for fill in fills {
                    if try store.fillMissingMediaDuration(itemId: fill.itemId, durationMs: fill.durationMs) { filled.append(fill.itemId) }
                }
                return filled
            }) ?? []
            guard !filled.isEmpty, let self else { return }
            self.hangTelemetry.labels.scoped("episodeLength") { self.episodeLengthWasFilled(itemIds: filled) }
        }
    }

    /// The store has new lengths: publish them to the Library rows, and to the item screen if it shows one of them,
    /// so "Length unknown" changes to the length.
    private func episodeLengthWasFilled(itemIds: [String]) {
        refreshLibraryRowsInBackground(mustPublish: true)
        if itemIds.contains(activeItemId) { refreshSelectedItemInBackground() }
    }
}
