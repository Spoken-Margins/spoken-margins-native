import Foundation

/// Everything the Library rows are built from, read from the store in one pass (#980).
/// `SessionKitPersistence` adds `read(store:)`; the row builder takes the snapshot as a value.
public struct LibraryReadSnapshot: Sendable {
    public let items: [LibraryItemSummary]
    public let sessions: [Session]
    public let manifests: [PreparedAudioManifestSummary]
    public let jobs: [AudioPreparationJob]
    public let downloads: [PodcastDownloadRecord]
    public var structuredDocumentItemIds: Set<String> = []
    /// Margins other people shared, counted per item (#1792). Items with none are absent.
    public var sharedMarginsByItemId: [String: SharedMarginTally] = [:]
    /// The listener's own active Margins, counted per item (#2394). Items with none are absent.
    public var marginCountsByItemId: [String: Int] = [:]

    /// The items not in Recently Deleted, in the snapshot's order: what `listItemSummaries()` returns. A caller that
    /// already holds the snapshot asks this instead of reading the item table again (#2507).
    public var liveItems: [LibraryItemSummary] { items.filter { $0.deletedAt == nil } }

    public init(
        items: [LibraryItemSummary],
        sessions: [Session],
        manifests: [PreparedAudioManifestSummary],
        jobs: [AudioPreparationJob],
        downloads: [PodcastDownloadRecord],
        structuredDocumentItemIds: Set<String> = [],
        sharedMarginsByItemId: [String: SharedMarginTally] = [:],
        marginCountsByItemId: [String: Int] = [:]
    ) {
        self.items = items
        self.sessions = sessions
        self.manifests = manifests
        self.jobs = jobs
        self.downloads = downloads
        self.structuredDocumentItemIds = structuredDocumentItemIds
        self.sharedMarginsByItemId = sharedMarginsByItemId
        self.marginCountsByItemId = marginCountsByItemId
    }

    public init(
        items: [Item],
        sessions: [Session],
        manifests: [PreparedAudioManifestSummary],
        jobs: [AudioPreparationJob],
        downloads: [PodcastDownloadRecord],
        structuredDocumentItemIds: Set<String> = [],
        sharedMarginsByItemId: [String: SharedMarginTally] = [:],
        marginCountsByItemId: [String: Int] = [:]
    ) {
        self.init(
            items: items.map(LibraryItemSummary.init), sessions: sessions, manifests: manifests, jobs: jobs,
            downloads: downloads, structuredDocumentItemIds: structuredDocumentItemIds,
            sharedMarginsByItemId: sharedMarginsByItemId, marginCountsByItemId: marginCountsByItemId)
    }
}
