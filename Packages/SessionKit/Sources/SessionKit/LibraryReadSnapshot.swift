import Foundation

/// Everything the Library rows are built from, read from the store in one pass (#980).
/// `SessionKitPersistence` adds `read(store:)`; the row builder takes the snapshot as a value.
public struct LibraryReadSnapshot: Sendable {
    public let items: [Item]
    public let sessions: [Session]
    public let manifests: [PreparedAudioManifest]
    public let jobs: [AudioPreparationJob]
    public let downloads: [PodcastDownloadRecord]
    public var structuredDocumentItemIds: Set<String> = []

    public init(
        items: [Item],
        sessions: [Session],
        manifests: [PreparedAudioManifest],
        jobs: [AudioPreparationJob],
        downloads: [PodcastDownloadRecord],
        structuredDocumentItemIds: Set<String> = []
    ) {
        self.items = items
        self.sessions = sessions
        self.manifests = manifests
        self.jobs = jobs
        self.downloads = downloads
        self.structuredDocumentItemIds = structuredDocumentItemIds
    }
}
