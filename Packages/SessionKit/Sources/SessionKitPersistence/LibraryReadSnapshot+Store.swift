import Foundation
import SessionKit

extension LibraryReadSnapshot {
    /// One pass over the store, in the order the Library has always read it.
    public static func read(store: SQLiteSessionStore, hiddenSenders: HiddenSenders = HiddenSenders()) throws -> Self {
        var snapshot = try Self(items: store.listItemSummaries(includeDeleted: true), sessions: store.loadSessions(),
                 manifests: store.loadPreparedAudioManifestSummaries(), jobs: store.loadAudioPreparationJobs(),
                 downloads: store.loadPodcastDownloads(), structuredDocumentItemIds: store.loadStructuredDocumentItemIds(),
                 sharedMarginsByItemId: store.loadSharedMarginTallies(hiding: hiddenSenders),
                 marginCountsByItemId: store.loadActiveMarginCountsByItem(),
                 friendMarginsArrivedAtByItemId: store.loadFriendMarginsArrivals(hiding: hiddenSenders))
        // A collection or folder record that can't be read leaves the chips and folder rows as they were; it never takes the
        // Library's rows with it, and never makes a folder's items appear flat.
        snapshot.collections = try? store.loadItemCollections()
        snapshot.libraryFolders = try? store.loadLibraryFolders()
        return snapshot
    }
}
