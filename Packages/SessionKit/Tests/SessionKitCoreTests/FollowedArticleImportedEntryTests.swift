import Foundation
import XCTest
import SessionKit
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
}
