import Foundation
import SessionKit
import SessionKitPersistence

struct LibraryReadSnapshot: Sendable {
    let items: [Item]
    let sessions: [Session]
    let manifests: [PreparedAudioManifest]
    let jobs: [AudioPreparationJob]
    let downloads: [PodcastDownloadRecord]
    var structuredDocumentItemIds: Set<String> = []

    static func read(store: SQLiteSessionStore) throws -> Self {
        try Self(items: store.listItems(includeDeleted: true), sessions: store.loadSessions(),
                 manifests: store.loadPreparedAudioManifests(), jobs: store.loadAudioPreparationJobs(),
                 downloads: store.loadPodcastDownloads(), structuredDocumentItemIds: store.loadStructuredDocumentItemIds())
    }
}
