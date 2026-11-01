import Foundation
import SessionKit

/// The reads and the save behind "queue an episode map for every downloaded episode that has none" (#2509, fix class
/// `store-write`). The app runs both halves on a background task; a Library of a few hundred rows used to run them on
/// the main thread, one spine check, one summary read and one job read per row, every time the preparation queue
/// refreshed.
///
/// The app asks for `candidates` first, then keeps only the ids whose downloaded file is still there (that check
/// belongs to the download coordinator on the main actor), then asks to `enqueue` what is left.
public enum AutomaticEpisodeMapJobs {
    /// The key `StoreReader.readInOrder` runs the saves under, so two overlapping refreshes queue jobs one at a time.
    public static let orderKey = "automatic-episode-map-jobs"

    /// The job's id for an item: stable, so queueing twice saves the same row.
    public static func jobId(itemId: String) -> String {
        "episode-map-job-\(PodcastAnchorEvidencePaths.safeComponent(itemId))"
    }

    /// The ids, in the order given, of items that are podcast episodes (a native media file or a remote stream) and
    /// have no saved episode map. Reads a yes/no for the map and the item's summary, never the map or the article.
    public static func candidates(itemIds: [String], store: SQLiteSessionStore) -> [String] {
        itemIds.filter { id in
            // A map this build can't decode still counts as a map, so it is kept and not rebuilt over (#2506).
            guard (try? store.hasEditionFingerprintSpine(itemId: id)) != true,
                  let item = try? store.loadItemSummary(id: id) else { return false }
            return item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream
        }
    }

    /// Saves a `policy` job for each item that has no live one and still no map. A cancelled job is replaced, as before. Returns the
    /// ids it saved a job for.
    @discardableResult
    public static func enqueue(
        itemIds: [String],
        policy: PreparationJobPolicy,
        store: SQLiteSessionStore
    ) -> [String] {
        var saved: [String] = []
        for itemId in itemIds {
            let id = jobId(itemId: itemId)
            // A map can finish between `candidates` and now; a job saved over it would transcribe the episode again.
            if (try? store.hasEditionFingerprintSpine(itemId: itemId)) == true { continue }
            if let existing = try? store.loadEpisodeMapPreparationJob(id: id), !existing.isCancelled { continue }
            do {
                try store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(id: id, itemId: itemId, policy: policy))
                saved.append(itemId)
            } catch {
                continue
            }
        }
        return saved
    }
}
