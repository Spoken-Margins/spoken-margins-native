import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class ListeningSignalCollectorTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private var recorder: ListeningSignalRecorder!
    private let epoch = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        try seed(store)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testWaitingFailureAndRecordingNeverBecomeListening() {
        let collector = ListeningSignalCollector(recorder: recorder)
        for status in [PlaybackStatus.starting, .failed, .recording, .paused, .idle] {
            for second in [0, 2] {
                collector.playbackProgress(itemId: "item", status: status, repository: store, at: epoch.addingTimeInterval(Double(second)))
            }
        }
        collector.flush()
        XCTAssertTrue(recorder.signals().isEmpty)
    }

    func testStartingBetweenConfirmedIntervalsClosesAtTheLastPlayingTick() {
        let collector = ListeningSignalCollector(recorder: recorder)
        for (second, status) in [(0, PlaybackStatus.starting), (2, .starting), (10, .playing), (12, .playing),
                                 (14, .starting), (16, .starting), (30, .playing), (31, .playing), (32, .paused)] {
            collector.playbackProgress(itemId: "item", status: status, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.flush()
        let signals = recorder.signals()
        XCTAssertEqual(signals.map(\.event), [.listened(seconds: 2), .listened(seconds: 1)])
        XCTAssertEqual(signals.map(\.at), [epoch.addingTimeInterval(10), epoch.addingTimeInterval(30)])
        XCTAssertEqual(signals.map { $0.item?.id }, ["entry", "entry"])
    }

    /// A network stall leaves the session reading as playing while the player waits; that time is not listening.
    /// A brief wait between rendered sentences stays inside the interval.
    func testAStallWhileTheSessionReadsPlayingIsNotListening() {
        let collector = ListeningSignalCollector(recorder: recorder)
        let stall: [(Int, PlaybackTransportState)] = [(0, .playing), (2, .playing)]
            + stride(from: 4, through: 20, by: 2).map { ($0, .waiting) } + [(22, .playing), (24, .playing)]
        let sentenceGap: [(Int, PlaybackTransportState)] = [(100, .playing), (102, .waiting), (104, .playing), (106, .playing)]
        for (second, transport) in stall + sentenceGap {
            collector.playbackProgress(itemId: "item", status: .playing, transport: transport, repository: store,
                                       at: epoch.addingTimeInterval(Double(second)))
        }
        collector.flush()
        let signals = recorder.signals()
        XCTAssertEqual(signals.map(\.event), [.listened(seconds: 2), .listened(seconds: 2), .listened(seconds: 6)])
        XCTAssertEqual(signals.map(\.at), [0, 22, 100].map { epoch.addingTimeInterval($0) })
    }

    func testBlockedContextReadDoesNotBlockTheCallerOrReorderPause() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let returned = expectation(description: "playback tick returned before context read was released")
        let collector = ListeningSignalCollector(recorder: recorder, resolve: { id, repository in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return ListeningSignalContext.load(forItemId: id, from: repository)
        })
        let repository = store!, time = epoch
        DispatchQueue.global().async {
            collector.playbackProgress(itemId: "item", status: .playing, repository: repository, at: time)
            collector.playbackProgress(itemId: "item", status: .playing, repository: repository, at: time.addingTimeInterval(2))
            collector.endListening()
            returned.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        wait(for: [returned], timeout: 1)
        release.signal()
        collector.flush()
        XCTAssertEqual(recorder.signals().map(\.event), [.listened(seconds: 2)])
    }

    func testContextIsCachedForTicksAndRefreshedAfterStop() throws {
        let count = Counter()
        let collector = ListeningSignalCollector(recorder: recorder, resolve: { id, repository in
            count.increment()
            return ListeningSignalContext.load(forItemId: id, from: repository)
        })
        for second in 0...4 {
            collector.playbackProgress(itemId: "item", status: .playing, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.endListening()
        collector.flush()
        XCTAssertEqual(count.value, 1)
        var subscription = try XCTUnwrap(store.loadFeedSubscriptions().first)
        subscription.source.title = "Renamed"
        try store.saveFeedSubscription(subscription)
        for second in 10...11 {
            collector.playbackProgress(itemId: "item", status: .playing, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.endListening()
        collector.flush()
        XCTAssertEqual(count.value, 2)
        XCTAssertEqual(recorder.signals().map { $0.source.title }, ["Notes", "Renamed"])
    }

    /// #1340: the item had no followed source when playback began, so the collector cached "none".
    /// Then the item got the source link of a feed already followed, with the subscriptions untouched
    /// and no stop in between. Only the item's own fields tell the collector to look again.
    func testAnItemThatGainsAFollowedSourceMidPlaybackIsCreditedWithoutTheSubscriptionsChanging() throws {
        try store.saveItem(Item(id: "plain", title: "Plain", mediaType: "article", text: "Words",
                                externalReference: nil, status: "ready"))
        let subscriptions = try store.loadFeedSubscriptions()
        let collector = ListeningSignalCollector(recorder: recorder)
        for second in 0...2 {
            collector.playbackProgress(itemId: "plain", status: .playing, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.flush()
        XCTAssertTrue(recorder.signals().isEmpty, "no followed source yet, so nothing to credit")

        var item = try store.loadItem(id: "plain")
        item.sourceURL = "https://example.com/feed"
        try store.saveItem(item)
        XCTAssertEqual(try store.loadFeedSubscriptions(), subscriptions)
        for second in 10...12 {
            collector.playbackProgress(itemId: "plain", status: .playing, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.endListening()
        collector.flush()

        XCTAssertEqual(recorder.signals().map(\.event), [.listened(seconds: 2)])
        XCTAssertEqual(recorder.signals().map { $0.source.id }, ["source"])
    }

    /// #1048 (PERSIST-11): the test above renames the subscription between the spells, which makes
    /// the collector re-resolve whatever stopping did. Here nothing about the follows changes, only
    /// the item's link to a feed entry, so a cache that survived the stop would keep the old entry.
    func testStoppingForgetsTheItemsContextEvenWhenTheFollowsDidNotChange() throws {
        let count = Counter()
        let collector = ListeningSignalCollector(recorder: recorder, resolve: { id, repository in
            count.increment()
            return ListeningSignalContext.load(forItemId: id, from: repository)
        })
        for second in 0...4 {
            collector.playbackProgress(itemId: "item", status: .playing, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.endListening()
        collector.flush()
        XCTAssertEqual(count.value, 1)

        try store.saveFeedEntry(FeedEntry(id: "entry-2", subscriptionId: "subscription",
            canonicalURL: "https://example.com/posts/2", title: "Two", publishedAt: epoch))
        var item = try store.loadItem(id: "item")
        item.externalReference = "https://example.com/posts/2"
        try store.saveItem(item)
        for second in 10...11 {
            collector.playbackProgress(itemId: "item", status: .playing, repository: store, at: epoch.addingTimeInterval(Double(second)))
        }
        collector.endListening()
        collector.flush()

        XCTAssertEqual(count.value, 2, "the second spell resolves the item again")
        XCTAssertEqual(recorder.signals().map { $0.item?.id }, ["entry", "entry-2"],
                       "and files its listening under the entry the item is linked to now")
    }

    func testQueuedArticleActionsAreIncludedInExplicitExportAndKeepPacketProvenance() throws {
        let collector = ListeningSignalCollector(recorder: recorder)
        collector.record(.margin(kind: .written, length: 12), itemId: "item", repository: store, at: epoch)
        collector.record(.margin(kind: .spoken, length: 4), itemId: "item", repository: store, at: epoch)
        collector.record(.export(packetId: "ours", marginCount: 2), itemId: "item", repository: store, at: epoch)
        collector.packetImport(itemId: "item", packetId: "ours", marginCount: 2, repository: store, at: epoch)
        collector.packetImport(itemId: "item", packetId: "theirs", marginCount: 1, repository: store, at: epoch)
        collector.record(.finish, itemId: "item", repository: store, at: epoch)
        collector.record(.share, itemId: "item", repository: store, at: epoch)
        collector.dismiss(entryId: "entry", repository: store, at: epoch)
        let url = try XCTUnwrap(collector.exportCopy(to: root.appendingPathComponent("export")))
        let signals = ListeningSignalRecorder.read(url)
        XCTAssertEqual(signals.map(\.event), [.margin(kind: .written, length: 12), .margin(kind: .spoken, length: 4),
            .export(packetId: "ours", marginCount: 2), .packetImport(packetId: "ours", fromOther: false, marginCount: 2),
            .packetImport(packetId: "theirs", fromOther: true, marginCount: 1), .finish, .share, .dismiss])
        XCTAssertTrue(signals.allSatisfy { $0.source.id == "source" && $0.item?.id == "entry" })
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("https://"))
    }

    /// #867: an export from an item with no followed source logs no row, so after the listener
    /// followed that source (and the app relaunched) their own packet read as from someone else.
    func testAnExportFromAnUnfollowedItemStillMarksItsPacketAsOurs() throws {
        let library = try SQLiteSessionStore(path: root.appendingPathComponent("unfollowed.sqlite").path)
        try library.saveItem(Item(id: "item", title: "One", mediaType: "article", text: "Words",
                                  externalReference: "https://example.com/posts/1", status: "ready"))
        let log = root.appendingPathComponent("relaunch", isDirectory: true).appendingPathComponent("signals.jsonl")

        let first = ListeningSignalCollector(recorder: ListeningSignalRecorder(fileURL: log, flushDelay: 60))
        first.record(.export(packetId: "ours", marginCount: 2), itemId: "item", repository: library, at: epoch)
        first.flush()
        XCTAssertTrue(ListeningSignalRecorder.read(log).isEmpty, "an item without a followed source still logs no row")

        try library.saveFeedSubscription(FeedSubscription(id: "subscription", source: SourceIdentity(
            id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Notes")))
        try library.saveFeedEntry(FeedEntry(id: "entry", subscriptionId: "subscription",
            canonicalURL: "https://example.com/posts/1", title: "One", publishedAt: epoch))

        let relaunched = ListeningSignalCollector(recorder: ListeningSignalRecorder(fileURL: log, flushDelay: 60))
        relaunched.packetImport(itemId: "item", packetId: "ours", marginCount: 2, repository: library, at: epoch)
        relaunched.packetImport(itemId: "item", packetId: "theirs", marginCount: 1, repository: library, at: epoch)
        relaunched.flush()
        XCTAssertEqual(ListeningSignalRecorder.read(log).map(\.event), [
            .packetImport(packetId: "ours", fromOther: false, marginCount: 2),
            .packetImport(packetId: "theirs", fromOther: true, marginCount: 1),
        ])
    }

    private func seed(_ repository: SQLiteSessionStore) throws {
        try repository.saveFeedSubscription(FeedSubscription(id: "subscription", source: SourceIdentity(
            id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Notes")))
        try repository.saveFeedEntry(FeedEntry(id: "entry", subscriptionId: "subscription",
            canonicalURL: "https://example.com/posts/1", title: "One", publishedAt: epoch))
        try repository.saveItem(Item(id: "item", title: "One", mediaType: "article", text: "Words",
                                    externalReference: "https://example.com/posts/1", status: "ready"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
