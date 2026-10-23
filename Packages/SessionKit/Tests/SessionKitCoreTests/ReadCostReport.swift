import Foundation
@testable import SessionKit
@testable import SessionKitPersistence

/// Runs every public `SQLiteSessionStore` read against a `LibraryFixture` and prints one table: read, milliseconds,
/// rows and bytes decoded at each scale (#2258). Times are the median of five runs after one warm-up, wall clock
/// on whatever machine runs it, so compare scales and reads within one table, not tables from different machines.
struct ReadCostReport {
    struct Row {
        var read: String
        var milliseconds: Double
        var rows: Int
        var bytes: Int
        var queries: Int
    }

    private var scales: [(scale: LibraryFixture.Scale, textMB: Double, rows: [Row])] = []

    mutating func add(scale: LibraryFixture.Scale, fixture: LibraryFixture, rows: [Row]) {
        scales.append((scale, Double(fixture.textBytes) / 1_000_000, rows))
    }

    /// The reads, with the ids a real screen would pass: the mapped podcast, one article, one session.
    static func reads(_ store: SQLiteSessionStore, article: String) -> [(name: String, run: () throws -> Void)] {
        let mapped = LibraryFixture.mappedItemId
        return [
            ("listItems()", { _ = try store.listItems() }),
            ("listDeletedItems()", { _ = try store.listDeletedItems() }),
            ("loadItem(article)", { _ = try store.loadItem(id: article) }),
            ("loadItem(mapped)", { _ = try store.loadItem(id: mapped) }),
            ("loadSessions()", { _ = try store.loadSessions() }),
            ("loadSessions(itemId: article)", { _ = try store.loadSessions(itemId: article) }),
            ("loadSession(id:)", { _ = try store.loadSession(id: "session-0") }),
            ("loadInterjections(itemId: mapped)", { _ = try store.loadInterjections(itemId: mapped) }),
            ("loadInterjections(sessionId:)", { _ = try store.loadInterjections(sessionId: "session-0") }),
            ("loadTurns(sessionId:)", { _ = try store.loadTurns(sessionId: "session-0") }),
            ("loadListeningMap(mapped)", { _ = try store.loadListeningMap(itemId: mapped) }),
            ("loadTranscriptTimeline(itemId: mapped)", { _ = try store.loadTranscriptTimeline(itemId: mapped) }),
            ("loadTranscriptTimelineSummary(mapped)", { _ = try store.loadTranscriptTimelineSummary(itemId: mapped) }),
            ("transcriptTimelineStamp(mapped)", { _ = try store.transcriptTimelineStamp(itemId: mapped) }),
            ("sourceTranscriptSizes()", { _ = try store.sourceTranscriptSizes() }),
            ("loadAudioAssets(itemId: mapped)", { _ = try store.loadAudioAssets(itemId: mapped) }),
            ("loadCanonicalSource(article)", { _ = try store.loadCanonicalSource(itemId: article) }),
            ("loadStructuredDocument(article)", { _ = try store.loadStructuredDocument(itemId: article) }),
            ("loadStructuredDocumentItemIds()", { _ = try store.loadStructuredDocumentItemIds() }),
            ("loadResolvedListeningMapProjection(mapped)", { _ = try store.loadResolvedListeningMapProjection(itemId: mapped) }),
            ("loadPortableListeningMapProposals(mapped)", { _ = try store.loadPortableListeningMapProposals(itemId: mapped) }),
            ("loadImportedCommentaryLayers()", { _ = try store.loadImportedCommentaryLayers() }),
            ("loadSharedMarginTallies()", { _ = try store.loadSharedMarginTallies() }),
            ("loadPodcastDownloads()", { _ = try store.loadPodcastDownloads() }),
            ("loadPreparedAudioManifests()", { _ = try store.loadPreparedAudioManifests() }),
            ("loadAudioPreparationJobs()", { _ = try store.loadAudioPreparationJobs() }),
            ("loadEpisodeMapPreparationJobs()", { _ = try store.loadEpisodeMapPreparationJobs() }),
            ("loadOwnedOfflineAssets()", { _ = try store.loadOwnedOfflineAssets() }),
            ("loadOfflineStorageReservations()", { _ = try store.loadOfflineStorageReservations() }),
            ("loadItemCollections()", { _ = try store.loadItemCollections() }),
            ("loadFeedSubscriptions()", { _ = try store.loadFeedSubscriptions() }),
            ("loadFeedEntries(all)", { _ = try store.loadFeedEntries(subscriptionId: nil) }),
            ("loadFeedEntries(one source)", { _ = try store.loadFeedEntries(subscriptionId: "feed-1") }),
            ("hasLiveItem(id:)", { _ = try store.hasLiveItem(id: article) }),
            ("hasActiveInterjection()", { _ = try store.hasActiveInterjection() }),
            ("loadItemSummary(id:)", { _ = try store.loadItemSummary(id: article) }),
            ("allMarginAudioPaths()", { _ = try store.allMarginAudioPaths() }),
            ("quarantinedRecordCount()", { _ = try store.quarantinedRecordCount() })
        ] + backgroundReads(store, article: article) + screens(store, article: article)
    }

    /// The reads the first table left out because the fixture had nothing in their tables (#2513): jobs, manifests,
    /// downloads, offline assets, imported layers, canonical sources, publisher audio, community uploads and the
    /// mapped podcast's episode-map artifacts. Ids are the ones `LibraryFixture.writeBackgroundTables` seeds.
    static func backgroundReads(_ store: SQLiteSessionStore, article: String) -> [(name: String, run: () throws -> Void)] {
        let mapped = LibraryFixture.mappedItemId
        let manifest = "manifest-\(article)"
        return [
            ("listItemSummaries()", { _ = try store.listItemSummaries() }),
            ("listItemSummaries(includeDeleted)", { _ = try store.listItemSummaries(includeDeleted: true) }),
            ("itemRevision(article)", { _ = store.itemRevision(id: article) }),
            ("loadPodcastDownload(itemId: mapped)", { _ = try store.loadPodcastDownload(itemId: mapped) }),
            ("loadPreparedAudioManifest(id:)", { _ = try store.loadPreparedAudioManifest(id: manifest) }),
            ("loadPreparedAudioManifests(itemId:)", { _ = try store.loadPreparedAudioManifests(itemId: article) }),
            ("loadOfflineStorageBudget()", { _ = try store.loadOfflineStorageBudget() }),
            ("loadAIJobs(sessionId:)", { _ = try store.loadAIJobs(sessionId: "session-0") }),
            ("loadWatchAudioPackage(id:)", { _ = try store.loadWatchAudioPackage(id: "watch-package-0") }),
            ("loadWatchAudioPackages(itemId:)", { _ = try store.loadWatchAudioPackages(itemId: mapped) }),
            ("loadWatchSyncEvents(sessionId:)", { _ = try store.loadWatchSyncEvents(sessionId: "session-0") }),
            ("loadWatchSyncEvent(id:)", { _ = try store.loadWatchSyncEvent(id: "watch-event-0") }),
            ("loadWatchPackageRequests(itemId:)", { _ = try store.loadWatchPackageRequests(itemId: mapped) }),
            ("loadTranscriptTimeline(id:)", { _ = try store.loadTranscriptTimeline(id: "timeline-1") }),
            ("loadTranscriptTimelineChapters(mapped)", { _ = try store.loadTranscriptTimelineChapters(itemId: mapped) }),
            ("resolveSourceAnchorContexts(mapped)", { _ = try store.resolveSourceAnchorContexts(itemId: mapped, mediaTimesMs: [60_000, 1_800_000, 3_600_000]) }),
            ("loadEditionFingerprintSpine(mapped)", { _ = try store.loadEditionFingerprintSpine(itemId: mapped) }),
            ("loadTranscriptPhraseSketch(mapped)", { _ = try store.loadTranscriptPhraseSketch(itemId: mapped) }),
            ("loadFeedRefreshState(subscriptionId:)", { _ = try store.loadFeedRefreshState(subscriptionId: "feed-1") }),
            ("loadSourceSuggestionDecision(sourceId:)", { _ = try store.loadSourceSuggestionDecision(sourceId: "source-0") }),
            ("loadPublisherAudio(itemId:)", { _ = try store.loadPublisherAudio(itemId: LibraryFixture.podcastItemId(1)) }),
            ("loadCommunityMapUpload(episodeKey:)", { _ = try store.loadCommunityMapUpload(episodeKey: "upload-1") }),
            ("loadCommunityMapUploads()", { _ = try store.loadCommunityMapUploads() }),
            ("loadInterjectionShareRevisions(interjectionId:)", { _ = try store.loadInterjectionShareRevisions(interjectionId: "note-1") }),
            ("loadImportedCommentaryLayer(id:)", { _ = try store.loadImportedCommentaryLayer(id: "layer-0") }),
            ("loadImportedCommentaryLayer(packageDigest:)", { _ = try store.loadImportedCommentaryLayer(packageDigest: "digest-0") }),
            ("loadImportedCommentaryLayers(itemId:)", { _ = try store.loadImportedCommentaryLayers(itemId: article) }),
            ("loadImportedCommentaryInterjections(layerId:)", { _ = try store.loadImportedCommentaryInterjections(layerId: "layer-0") }),
            ("isLiveImportedCommentaryLayer(id:)", { _ = try store.isLiveImportedCommentaryLayer(id: "layer-0") }),
            ("hasImportedWatchSyncEvent(id:)", { _ = try store.hasImportedWatchSyncEvent(id: "watch-event-0") }),
            ("importedCommentaryRecordsMention(_:)", { _ = try store.importedCommentaryRecordsMention("no-such-needle") }),
            ("marginNoteChanges(after:)", { _ = try store.marginNoteChanges(after: "2000-01-01 00:00:00") }),
            ("quarantinedMarginAudioPaths(itemId:)", { _ = try store.quarantinedMarginAudioPaths(itemId: mapped) })
        ]
    }

    /// What a screen or a launch does with the store: several reads in a row, the way the app composes them. Each
    /// replica mirrors the app code named in its label, because the app target cannot be built on a host; if that
    /// code changes, change the replica (the read list is what the cost depends on, not the types it fills).
    static func screens(_ store: SQLiteSessionStore, article: String) -> [(name: String, run: () throws -> Void)] {
        let mapped = LibraryFixture.mappedItemId
        return [
            ("screen: LibraryReadSnapshot.read(store:)", { _ = try LibraryReadSnapshot.read(store: store) }),
            ("screen: refreshAudioPreparationPresentation", {
                // Gate1AppModel+LibraryAudioQueue.refreshAudioPreparationPresentation(store:), minus the stale-job delete.
                _ = try store.listItemSummaries()
                _ = try store.loadPreparedAudioManifests()
                _ = try store.loadAudioPreparationJobs()
                _ = try store.loadSessions()
            }),
            ("screen: refreshMarginRows (MarginCollection.build)", {
                // Gate1AppModel.refreshMarginRows(): one pass over every session's Margins and every shared layer.
                _ = try MarginCollection.build(
                    items: store.listItems(), sessions: store.loadSessions(),
                    loadMap: { try? store.loadListeningMap(itemId: $0) },
                    loadMediaChapters: { (try? store.loadTranscriptTimelineChapters(itemId: $0)) ?? [] },
                    loadInterjections: { try store.loadInterjections(sessionId: $0) },
                    loadImportedLayers: { try store.loadImportedCommentaryLayers() },
                    loadImportedInterjections: { try store.loadImportedCommentaryInterjections(layerId: $0) })
            }),
            ("screen: ItemDetailLoader.load(article)", {
                _ = try ItemDetailLoader.load(id: article, store: store, snapshotItemId: nil, snapshotSessionId: nil,
                                              placementPasses: SharedMarginPlacementPasses())
            }),
            ("screen: ItemDetailLoader.load(mapped)", {
                _ = try ItemDetailLoader.load(id: mapped, store: store, snapshotItemId: nil, snapshotSessionId: nil,
                                              placementPasses: SharedMarginPlacementPasses())
            })
        ]
    }

    static func measure(_ fixture: LibraryFixture) throws -> [Row] {
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)
        var rows: [Row] = []
        for (name, run) in reads(store, article: fixture.articleItemId) {
            try run()   // warm-up: statement and page caches
            var times: [Double] = []
            for _ in 0..<5 {
                meter.reset()
                let start = DispatchTime.now().uptimeNanoseconds
                try run()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let samples = meter.samples
            rows.append(Row(
                read: name, milliseconds: times.sorted()[times.count / 2],
                rows: samples.reduce(0) { $0 + $1.rows }, bytes: samples.reduce(0) { $0 + $1.bytes },
                queries: samples.count))
        }
        return rows
    }

    func markdown() -> String {
        guard let first = scales.first else { return "" }
        var out = "| read |"
        for entry in scales { out += " \(entry.scale.name): ms | rows | bytes |" }
        out += "\n|---|" + String(repeating: "---:|---:|---:|", count: scales.count) + "\n"
        for (index, row) in first.rows.enumerated() {
            out += "| `\(row.read)` |"
            for entry in scales {
                let r = entry.rows[index]
                out += " \(Self.format(r.milliseconds)) | \(r.rows) | \(Self.bytes(r.bytes)) |"
            }
            out += "\n"
        }
        out += "\nScales: " + scales.map {
            "\($0.scale.name) = \($0.scale.items) items, \($0.scale.sessions) sessions, \($0.scale.sources) sources, \($0.scale.entries) entries, \(String(format: "%.1f", $0.textMB)) MB article text"
        }.joined(separator: "; ") + "\n"
        return out
    }

    private static func format(_ ms: Double) -> String { ms < 10 ? String(format: "%.2f", ms) : String(format: "%.0f", ms) }

    private static func bytes(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1f MB", Double(count) / 1_000_000)
            : count >= 1_000 ? String(format: "%.1f KB", Double(count) / 1_000) : "\(count)"
    }
}
