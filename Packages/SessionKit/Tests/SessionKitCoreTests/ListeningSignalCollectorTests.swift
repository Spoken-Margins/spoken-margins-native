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
