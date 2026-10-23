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
            ("loadCanonicalSource(mapped)", { _ = try store.loadCanonicalSource(itemId: mapped) }),
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
            ("allMarginAudioPaths()", { _ = try store.allMarginAudioPaths() }),
            ("quarantinedRecordCount()", { _ = try store.quarantinedRecordCount() })
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
