import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

final class ListeningSignalSubscriptionChangeTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private var recorder: ListeningSignalRecorder!
    private let epoch = Date(timeIntervalSince1970: 1_000)
    private var keepEvidence = false

    override func setUpWithError() throws {
        keepEvidence = ProcessInfo.processInfo.environment["LISTENING_EXPERIMENT_OUTPUT"] != nil
        let parent = ProcessInfo.processInfo.environment["LISTENING_EXPERIMENT_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        root = parent.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-"))-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        recorder = ListeningSignalRecorder(fileURL: root.appendingPathComponent("signals.jsonl"), flushDelay: 60)
        try store.saveItem(Item(id: "item", title: "One", mediaType: "article", text: "Words", externalReference: "https://example.com/posts/1", status: "ready"))
    }
    override func tearDownWithError() throws {
        recorder.flush(); store = nil; recorder = nil
        if !keepEvidence { try? FileManager.default.removeItem(at: root) }
    }
    private func follow() throws {
        try store.saveFeedSubscription(FeedSubscription(id: "subscription", source: SourceIdentity(id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Notes")))
        try store.saveFeedEntry(FeedEntry(id: "entry", subscriptionId: "subscription", canonicalURL: "https://example.com/posts/1", title: "One", publishedAt: epoch, state: .imported))
        var item = try store.loadItem(id: "item")
        // These are the same persistent relationship writes as accepted follow suggestion.
        item.sourceURL = "https://example.com/feed"; item.sourceTitle = "Notes"
        try store.saveItem(item)
    }
    private func ticks(_ seconds: [Int], _ collector: ListeningSignalCollector, repository: SQLiteSessionStore? = nil) {
        for second in seconds { collector.playbackProgress(itemId: "item", status: .playing, repository: repository ?? store, at: epoch.addingTimeInterval(Double(second))) }
    }
    private func export(_ collector: ListeningSignalCollector, phase: String) throws -> [ListeningSignal] {
        guard let file = try collector.exportCopy(to: root.appendingPathComponent(phase)) else { return [] }
        let rows = ListeningSignalRecorder.read(file)
        XCTAssertEqual(rows, ListeningSignalRecorder.read(recorder.fileURL))
        XCTAssertNil(recorder.writeError)
        return rows
    }
    private func evidence(_ scenario: String, _ rows: [ListeningSignal]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rows).write(to: root.appendingPathComponent("observed.json"))
        let seconds = rows.reduce(0.0) { result, row in if case .listened(let duration) = row.event { return result + duration }; return result }
        print("A2 scenario=\(scenario) rows=\(rows.count) listenedSeconds=\(seconds) sources=\(rows.map { $0.source.id }) root=\(root.path)")
    }
    private func afterFollow(reset: Bool = false, replaceRepository: Bool = false) throws {
        let collector = ListeningSignalCollector(recorder: recorder)
        XCTAssertNil(ListeningSignalContext.load(forItemId: "item", from: store))
        ticks([0, 1], collector); collector.flush() // Cache nil before the mutation has happened.
        try follow()
        XCTAssertEqual(ListeningSignalContext.load(forItemId: "item", from: store)?.source.id, "source")
        let reopened = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        XCTAssertEqual(try reopened.loadFeedSubscriptions().map(\.id), ["subscription"])
        XCTAssertEqual(try reopened.loadItem(id: "item").sourceURL, "https://example.com/feed")
        if reset { collector.endListening() }
        ticks([2, 3, 4], collector, repository: replaceRepository ? reopened : store)
        collector.endListening()
        // Action context is independently resolved, showing whether only listening was dropped.
        collector.record(.margin(kind: .written, length: 12), itemId: "item", repository: store, at: epoch.addingTimeInterval(4))
        let rows = try export(collector, phase: "export-after-follow")
        try evidence(reset ? "follow-with-reset" : replaceRepository ? "follow-replacement-store" : "follow-same-store", rows)
        XCTAssertEqual(rows.filter { $0.event == .margin(kind: .written, length: 12) }.count, 1)
        XCTAssertEqual(rows.filter { $0.event.name == "listened" }.map(\.event), [.listened(seconds: 2)], "Confirmed playing after a persisted follow must count even when the repository object stays the same")
        XCTAssertTrue(rows.allSatisfy { $0.source.id == "source" && $0.item?.id == "entry" })
    }
    private func afterUnfollow(reset: Bool = false) throws {
        try follow()
        let collector = ListeningSignalCollector(recorder: recorder)
        ticks([0, 1], collector); collector.flush()
        XCTAssertEqual(recorder.signals().map(\.event), [.listened(seconds: 1)])
        try store.deleteFeedSubscription(id: "subscription")
        XCTAssertTrue(try store.loadFeedSubscriptions().isEmpty)
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: nil).map(\.id), ["entry"], "Imported tombstone remains; subscription eligibility alone changed")
        XCTAssertNil(ListeningSignalContext.load(forItemId: "item", from: store))
        let reopened = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        XCTAssertTrue(try reopened.loadFeedSubscriptions().isEmpty)
        if reset { collector.endListening() }
        ticks([2, 3, 4], collector); collector.endListening()
        collector.record(.margin(kind: .written, length: 12), itemId: "item", repository: store, at: epoch.addingTimeInterval(4))
        let rows = try export(collector, phase: "export-after-unfollow")
        try evidence(reset ? "unfollow-with-reset" : "unfollow-same-store", rows)
        XCTAssertFalse(rows.contains { $0.event.name == "margin" }, "Fresh action context should recognize the unfollow")
        XCTAssertEqual(rows.map(\.event), [.listened(seconds: 1)], "The exported log must not add post-unfollow listening to a source that is no longer followed")
    }
    func testFollowDuringContinuousPlaybackRecognizesSameStoreMutation() throws { try afterFollow() }
    func testUnfollowDuringContinuousPlaybackStopsSameStoreAttribution() throws { try afterUnfollow() }
    func testPauseResetAfterFollowControl() throws { try afterFollow(reset: true) }
    func testPauseResetAfterUnfollowControl() throws { try afterUnfollow(reset: true) }
    func testRepositoryObjectReplacementAfterFollowControl() throws { try afterFollow(replaceRepository: true) }
    func testFollowBeforeFirstTickControl() throws {
        try follow(); let collector = ListeningSignalCollector(recorder: recorder)
        ticks([2, 3, 4], collector); collector.endListening()
        let rows = try export(collector, phase: "export-follow-first")
        try evidence("follow-before-first-tick", rows)
        XCTAssertEqual(rows.map(\.event), [.listened(seconds: 2)])
    }
}
