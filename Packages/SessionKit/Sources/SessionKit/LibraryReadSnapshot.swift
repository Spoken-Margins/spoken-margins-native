import Foundation

/// Everything the Library rows are built from, read from the store in one pass (#980).
/// `SessionKitPersistence` adds `read(store:)`; the row builder takes the snapshot as a value.
public struct LibraryReadSnapshot: Sendable {
    public let items: [LibraryItemSummary]
    public let sessions: [Session]
    public let manifests: [PreparedAudioManifest]
    public let jobs: [AudioPreparationJob]
    public let downloads: [PodcastDownloadRecord]
    public var structuredDocumentItemIds: Set<String> = []
    /// Margins other people shared, counted per item (#1792). Items with none are absent.
    public var sharedMarginsByItemId: [String: SharedMarginTally] = [:]

    public init(
        items: [LibraryItemSummary],
        sessions: [Session],
        manifests: [PreparedAudioManifest],
        jobs: [AudioPreparationJob],
        downloads: [PodcastDownloadRecord],
        structuredDocumentItemIds: Set<String> = [],
        sharedMarginsByItemId: [String: SharedMarginTally] = [:]
    ) {
        self.items = items
        self.sessions = sessions
        self.manifests = manifests
        self.jobs = jobs
        self.downloads = downloads
        self.structuredDocumentItemIds = structuredDocumentItemIds
        self.sharedMarginsByItemId = sharedMarginsByItemId
    }

    public init(
        items: [Item],
        sessions: [Session],
        manifests: [PreparedAudioManifest],
        jobs: [AudioPreparationJob],
        downloads: [PodcastDownloadRecord],
        structuredDocumentItemIds: Set<String> = [],
        sharedMarginsByItemId: [String: SharedMarginTally] = [:]
    ) {
        self.init(
            items: items.map(LibraryItemSummary.init), sessions: sessions, manifests: manifests, jobs: jobs,
            downloads: downloads, structuredDocumentItemIds: structuredDocumentItemIds,
            sharedMarginsByItemId: sharedMarginsByItemId)
    }
}
