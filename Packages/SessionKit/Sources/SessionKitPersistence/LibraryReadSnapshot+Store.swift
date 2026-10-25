import Foundation
import SessionKit

extension LibraryReadSnapshot {
    /// One pass over the store, in the order the Library has always read it.
    public static func read(store: SQLiteSessionStore) throws -> Self {
        try Self(items: store.listItemSummaries(includeDeleted: true), sessions: store.loadSessions(),
                 manifests: store.loadPreparedAudioManifests(), jobs: store.loadAudioPreparationJobs(),
                 downloads: store.loadPodcastDownloads(), structuredDocumentItemIds: store.loadStructuredDocumentItemIds(),
                 sharedMarginsByItemId: store.loadSharedMarginTallies(),
                 marginCountsByItemId: store.loadActiveMarginCountsByItem())
    }
}
