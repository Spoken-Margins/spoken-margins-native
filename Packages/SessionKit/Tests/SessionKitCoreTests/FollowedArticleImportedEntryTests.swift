import Foundation
import XCTest
@testable import SessionKit
import SessionKitFeeds
import SessionKitPersistence

final class FollowedArticleImportedEntryTests: XCTestCase {
    /// The item keeps the page's final URL (its sharing identity, J5); the signal rows still join the entry.
    func testRedirectedFeedCaptureKeepsItsFinalURLAndItsSignalEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let subscription = FeedSubscription(id: "followed", source: SourceIdentity(id: "publication", kind: .articleFeed,
            canonicalURL: "https://news.example/feed", host: "news.example", title: "News"))
        let entry = FeedEntry(id: "entry", subscriptionId: subscription.id,
            canonicalURL: "https://news.example/link", title: "Article", state: .imported)
        try store.saveFeedSubscription(subscription)
        try store.saveFeedEntry(entry)
        let capture = BrowserTextHandoff(captureMode: .readablePage,
            source: BrowserTextSource(url: "https://destination.example/article", title: "Article", author: "Writer"),
            text: "The captured body survives the redirect.")
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let handoff = ListeningSignalCollector(recorder: recorder).importedEntries.note(capture, for: entry)
        XCTAssertEqual(handoff, capture, "noting the entry leaves the import untouched")
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test",
            capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let imported = try engine.importBrowserTextInBackground(handoff)
        let item = try store.loadItem(id: imported.id)
        XCTAssertEqual(item.externalReference, capture.source.url, "a recipient's copy matches by the final URL")
        XCTAssertEqual(item.text, capture.text)
        // A fresh collector, as after a relaunch, reads the entry back from beside the log.
        let collector = ListeningSignalCollector(recorder: recorder)
        collector.record(.margin(kind: .written, length: 12), itemId: item.id, repository: store)
        let exported = try collector.exportCopy(to: root.appendingPathComponent("export"))
        let rows = exported.map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map { $0.item?.id }, [entry.id])
        XCTAssertEqual(rows.map { $0.source.id }, [subscription.source.id])
        XCTAssertEqual(rows.map(\.event), [.margin(kind: .written, length: 12)])
    }

    /// A publication's main feed and a topic feed both list the article; rows join the entry it was picked from.
    func testArticleListedByTwoFollowedFeedsJoinsTheEntryItWasImportedFrom() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let main = FeedSubscription(id: "main", source: SourceIdentity(id: "main-feed", kind: .articleFeed,
            canonicalURL: "https://news.example/feed", host: "news.example", title: "News"))
        let topic = FeedSubscription(id: "topic", source: SourceIdentity(id: "topic-feed", kind: .articleFeed,
            canonicalURL: "https://news.example/topic/feed", host: "news.example", title: "News: Science"))
        let fromMain = FeedEntry(id: "from-main", subscriptionId: main.id,
            canonicalURL: "https://news.example/article", title: "Article", state: .unseen)
        let fromTopic = FeedEntry(id: "from-topic", subscriptionId: topic.id,
            canonicalURL: "https://news.example/article", title: "Article", state: .imported)
        for subscription in [main, topic] { try store.saveFeedSubscription(subscription) }
        for entry in [fromMain, fromTopic] { try store.saveFeedEntry(entry) }
        let capture = BrowserTextHandoff(captureMode: .readablePage,
            source: BrowserTextSource(url: "https://news.example/article", title: "Article", author: "Writer"),
            text: "Both feeds list this article.")
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let handoff = ListeningSignalCollector(recorder: recorder).importedEntries.note(capture, for: fromTopic)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test",
            capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let item = try store.loadItem(id: try engine.importBrowserTextInBackground(handoff).id)

        let collector = ListeningSignalCollector(recorder: recorder)
        collector.record(.margin(kind: .written, length: 12), itemId: item.id, repository: store)
        let rows = try collector.exportCopy(to: root.appendingPathComponent("export")).map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map { $0.item?.id }, [fromTopic.id], "the row is kept and credited to the feed it was picked from")
        XCTAssertEqual(rows.map { $0.source.id }, [topic.source.id])
    }

    /// #865: the URL record belongs to whichever import came last, so a second edition imported from
    /// the other feed used to take over the first edition's rows. Each Library item keeps its own entry.
    func testSecondEditionFromAnotherFeedDoesNotTakeOverTheFirstEditionsEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let feedA = FeedSubscription(id: "a", source: SourceIdentity(id: "feed-a", kind: .articleFeed,
            canonicalURL: "https://news.example/feed", host: "news.example", title: "News"))
        let feedB = FeedSubscription(id: "b", source: SourceIdentity(id: "feed-b", kind: .articleFeed,
            canonicalURL: "https://news.example/topic/feed", host: "news.example", title: "News: Science"))
        let entryA = FeedEntry(id: "entry-a", subscriptionId: feedA.id,
            canonicalURL: "https://news.example/article", title: "Article", state: .imported)
        let entryB = FeedEntry(id: "entry-b", subscriptionId: feedB.id,
            canonicalURL: "https://news.example/article", title: "Article", state: .imported)
        for subscription in [feedA, feedB] { try store.saveFeedSubscription(subscription) }
        for entry in [entryA, entryB] { try store.saveFeedEntry(entry) }
        let recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test",
            capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        func importEdition(text: String, from entry: FeedEntry) throws -> Item {
            let importedEntries = ListeningSignalCollector(recorder: recorder).importedEntries
            let handoff = importedEntries.note(BrowserTextHandoff(captureMode: .readablePage,
                source: BrowserTextSource(url: "https://news.example/article", title: "Article", author: "Writer"),
                text: text), for: entry)
            let item = try store.loadItem(id: try engine.importBrowserTextInBackground(handoff).id)
            importedEntries.note(itemId: item.id, for: entry)
            return item
        }
        let first = try importEdition(text: "The first edition of the article.", from: entryA)
        let second = try importEdition(text: "The article changed, so this is a second edition.", from: entryB)
        XCTAssertNotEqual(first.id, second.id, "the text changed, so the engine keeps two Library editions")

        // A fresh collector, as after a relaunch, reads the records back from beside the log.
        let collector = ListeningSignalCollector(recorder: recorder)
        collector.record(.margin(kind: .written, length: 12), itemId: first.id, repository: store)
        collector.record(.margin(kind: .written, length: 7), itemId: second.id, repository: store)
        let rows = try collector.exportCopy(to: root.appendingPathComponent("export")).map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map(\.event), [.margin(kind: .written, length: 12), .margin(kind: .written, length: 7)])
        XCTAssertEqual(rows.map { $0.item?.id }, [entryA.id, entryB.id])
        XCTAssertEqual(rows.map { $0.source.id }, [feedA.source.id, feedB.source.id])
    }

    /// Neighbouring cases for the item-id record: an item imported before it existed, and a record
    /// naming an entry that is no longer on a followed feed, both fall back to the URL record.
    func testItemRecordFallsBackToTheURLRecordWhenItHasNothingBetter() throws {
        let feed = FeedSubscription(id: "a", source: SourceIdentity(id: "feed-a", kind: .articleFeed,
            canonicalURL: "https://news.example/feed", host: "news.example", title: "News"))
        let entry = FeedEntry(id: "entry-a", subscriptionId: feed.id,
            canonicalURL: "https://news.example/article", title: "Article", state: .imported)
        let item = Item(id: "item-1", title: "Article", mediaType: "article", text: "Words",
                        externalReference: "https://news.example/article", status: "ready")
        let url = try XCTUnwrap(FollowedSourceMatching.normalizedFollowSourceURL("https://news.example/article"))
        func entryId(_ records: [String: String]) -> String? {
            ListeningSignalContext.context(for: item, subscriptions: [feed], entries: [entry],
                                           importedEntryIds: records)?.item.id
        }
        XCTAssertEqual(entryId([url: entry.id]), entry.id, "no item record: the URL record decides, as before")
        XCTAssertEqual(entryId([ListeningSignalImportedEntries.itemKey(item.id): entry.id]), entry.id)
        XCTAssertEqual(entryId([url: entry.id, ListeningSignalImportedEntries.itemKey(item.id): "gone"]), entry.id,
                       "an item record naming an unknown entry is ignored")
        XCTAssertEqual(entryId([url: "other", ListeningSignalImportedEntries.itemKey("item-2"): "other"]), entry.id,
                       "another item's record is not this item's")
        XCTAssertEqual(entryId([:]), entry.id, "a unique page match still joins the entry with no records at all")
    }

    /// The notes are written behind the caller (#2509): a burst of them leaves every record on disk, in order,
    /// and a fresh instance (a relaunch) reads all of them back.
    func testABurstOfNotesIsWrittenBehindTheCallerAndReadBackByAFreshInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("followed-article-entries.json")
        let writer = ListeningSignalImportedEntries(fileURL: file)
        let entry = FeedEntry(id: "entry", subscriptionId: "sub", canonicalURL: "https://news.example/a", title: "A", state: .imported)
        for index in 0..<200 {
            writer.note(itemId: "item-\(index)", for: FeedEntry(id: "entry-\(index)", subscriptionId: entry.subscriptionId,
                canonicalURL: entry.canonicalURL, title: entry.title, state: .imported))
        }
        let reader = ListeningSignalImportedEntries(fileURL: file)
        let records = reader.entryIds()
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records[ListeningSignalImportedEntries.itemKey("item-199")], "entry-199")
        let onDisk = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk, records, "the file holds the last write, which has all 200 records")
    }
}
