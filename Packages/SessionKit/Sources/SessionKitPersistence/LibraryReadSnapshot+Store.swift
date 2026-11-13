import Foundation
import SessionKit

extension LibraryReadSnapshot {
    /// One pass over the store, in the order the Library has always read it.
    public static func read(store: SQLiteSessionStore, hiddenSenders: HiddenSenders = HiddenSenders()) throws -> Self {
        try Self(items: store.listItemSummaries(includeDeleted: true), sessions: store.loadSessions(),
                 manifests: store.loadPreparedAudioManifestSummaries(), jobs: store.loadAudioPreparationJobs(),
                 downloads: store.loadPodcastDownloads(), structuredDocumentItemIds: store.loadStructuredDocumentItemIds(),
                 sharedMarginsByItemId: store.loadSharedMarginTallies(hiding: hiddenSenders),
                 marginCountsByItemId: store.loadActiveMarginCountsByItem(),
                 friendMarginsArrivedAtByItemId: store.loadFriendMarginsArrivals(hiding: hiddenSenders))
    }
}
