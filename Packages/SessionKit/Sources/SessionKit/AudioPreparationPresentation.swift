import Foundation

/// The Preparing Audio screen's two lists and the stale jobs to drop, worked out from rows already read (#2505).
///
/// The app model used to read the store again for this after every Library reload, on the main thread. The Library
/// read already holds the items, sessions, manifests and jobs it needs, so a background reload now builds this from
/// that read and the main thread only publishes it. It is a pure function of its inputs; deleting `staleJobIds` is the
/// caller's step.
public struct AudioPreparationPresentation: Sendable, Equatable {
    public let queue: [AudioPreparationQueueRow]
    public let recentlyPrepared: [RecentlyPreparedAudioRow]
    /// Stored jobs whose item is gone, trashed or finished. They are already left out of `queue`.
    public let staleJobIds: [String]

    /// `items` may include trashed ones: a trashed item has no title here and its jobs are stale, as when only
    /// the Library's live items were read.
    public init<Item: LibraryItemFields>(
        items: [Item],
        sessions: [Session],
        manifests: [PreparedAudioManifestSummary],
        jobs: [AudioPreparationJob],
        activeItemId: String?
    ) {
        let live = items.filter { $0.deletedAt == nil }
        let stale = LibraryAudioPreparationAdmission.staleJobIds(
            jobs, items: live, sessionsByItemId: Dictionary(grouping: sessions, by: \.itemId))
        let titlesByItemId = Dictionary(live.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let manifestsById = Dictionary(manifests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = AudioPreparationQueueProjection.orderedJobs(jobs, staleJobIds: Set(stale), activeItemId: activeItemId)
        staleJobIds = stale
        queue = AudioPreparationQueueProjection.queueRows(
            jobs: ordered, manifestsById: manifestsById, titlesByItemId: titlesByItemId, activeItemId: activeItemId)
        recentlyPrepared = AudioPreparationQueueProjection.recentlyPrepared(manifests: manifests, titlesByItemId: titlesByItemId)
    }

    public init(snapshot: LibraryReadSnapshot, activeItemId: String?) {
        self.init(
            items: snapshot.items, sessions: snapshot.sessions, manifests: snapshot.manifests, jobs: snapshot.jobs,
            activeItemId: activeItemId)
    }
}
