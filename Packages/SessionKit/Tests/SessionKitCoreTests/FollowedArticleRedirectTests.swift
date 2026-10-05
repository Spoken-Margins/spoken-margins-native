import Foundation
import XCTest
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

final class FollowedArticleRedirectTests: XCTestCase {
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
        let handoff = ListeningSignalCollector(recorder: recorder).redirects.note(capture, for: entry)
        XCTAssertEqual(handoff, capture, "noting the redirect leaves the import untouched")
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test",
            capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let imported = try engine.importBrowserTextInBackground(handoff)
        let item = try store.loadItem(id: imported.id)
        XCTAssertEqual(item.externalReference, capture.source.url, "a recipient's copy matches by the final URL")
        XCTAssertEqual(item.text, capture.text)
        // A fresh collector, as after a relaunch, reads the redirect back from beside the log.
        let collector = ListeningSignalCollector(recorder: recorder)
        collector.record(.margin(kind: .written, length: 12), itemId: item.id, repository: store)
        let exported = try collector.exportCopy(to: root.appendingPathComponent("export"))
        let rows = exported.map(ListeningSignalRecorder.read) ?? []
        XCTAssertEqual(rows.map { $0.item?.id }, [entry.id])
        XCTAssertEqual(rows.map { $0.source.id }, [subscription.source.id])
        XCTAssertEqual(rows.map(\.event), [.margin(kind: .written, length: 12)])
    }
}
