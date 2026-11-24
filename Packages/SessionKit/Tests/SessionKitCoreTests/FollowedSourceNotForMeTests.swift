import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitPersistence

/// #4285 PR 3: an episode marked "Not for me" stays out of New for good. Unfollowing deletes a show's stored
/// entries, so following again used to bring every episode back as unseen; the coordinator now asks the Not for me
/// marks before it saves an entry. Real SQLite, a real marks file, and a feed served through a stub URL protocol.
final class FollowedSourceNotForMeTests: XCTestCase {
    private var root: URL!
    private var repository: SQLiteSessionStore!
    private let feedURL = "https://notforme.example/feed.json"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("not-for-me-feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        NotForMeFeedURLProtocol.episodeCount = 3
    }

    override func tearDownWithError() throws {
        repository = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func coordinator(marks: NotForMeSnapshotBox?) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotForMeFeedURLProtocol.self]
        return FollowedSourceCoordinator(
            repository: repository, session: URLSession(configuration: configuration), signals: nil,
            suppressedEntry: marks?.suppressedEntry
        )
    }

    private func store() -> NotForMeStore {
        NotForMeStore(fileURL: root.appendingPathComponent(NotForMeStore.fileName))
    }

    private func states(_ subscriptionID: String) throws -> [String: FeedEntryState] {
        Dictionary(uniqueKeysWithValues: try repository.loadFeedEntries(subscriptionId: subscriptionID).map { ($0.episodeGUID ?? "?", $0.state) })
    }

    /// Marks `guid`'s episode the way the app will: from the stored entry's own fields.
    private func mark(_ guid: String, in subscription: FeedSubscription, store: NotForMeStore) async throws {
        let entry = try XCTUnwrap(try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == guid })
        try await store.markItem(feedURL: subscription.source.canonicalURL, guid: entry.episodeGUID,
                                 canonicalURL: entry.canonicalURL, audioURL: entry.audioURL, title: entry.title)
    }

    func testAMarkedEpisodeStaysDismissedAfterUnfollowRefollowAndRefresh() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        let subscription = try await coordinator.follow(urlString: feedURL)
        try await mark("ep-2", in: subscription, store: store)
        try await coordinator.setEntryState(id: try XCTUnwrap(
            try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == "ep-2" }?.id), state: .dismissed)

        try await coordinator.unfollow(subscriptionId: subscription.id)
        XCTAssertTrue(try repository.loadFeedEntries(subscriptionId: subscription.id).isEmpty, "unfollow deletes the stored entries")

        let again = try await coordinator.follow(urlString: feedURL)
        XCTAssertEqual(try states(again.id)["ep-2"], .dismissed)
        XCTAssertEqual(try states(again.id)["ep-1"], .unseen)
        XCTAssertEqual(try states(again.id)["ep-3"], .unseen)
        let inNew = try await coordinator.entries()
        XCTAssertEqual(Set(inNew.compactMap(\.episodeGUID)), ["ep-1", "ep-3"], "the marked episode is not in New")

        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(try states(again.id)["ep-2"], .dismissed, "a refresh doesn't revive it")
    }

    /// The control: the same steps with no marks bring the episode back. This is what the provider fixes.
    func testWithoutTheMarksTheEpisodeComesBackAfterRefollow() async throws {
        let coordinator = coordinator(marks: nil)
        let subscription = try await coordinator.follow(urlString: feedURL)
        let id = try XCTUnwrap(try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == "ep-2" }?.id)
        try await coordinator.setEntryState(id: id, state: .dismissed)
        try await coordinator.unfollow(subscriptionId: subscription.id)
        let again = try await coordinator.follow(urlString: feedURL)
        XCTAssertEqual(try states(again.id)["ep-2"], .unseen)
    }

    func testAddEveryNewItemNeverImportsAMarkedEpisode() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        let subscription = try await coordinator.follow(urlString: feedURL)
        try await coordinator.setNewItemPolicy(subscriptionId: subscription.id, policy: .addEveryNewItem)
        // The listener marked episode 4 before it was published (from its page, say), and episode 5 is plain new.
        try await store.markItem(feedURL: subscription.source.canonicalURL, guid: "ep-4", canonicalURL: nil, audioURL: nil, title: "Episode 4")

        NotForMeFeedURLProtocol.episodeCount = 5
        let toAdd = await coordinator.refreshStale(force: true)

        XCTAssertEqual(toAdd.compactMap(\.episodeGUID), ["ep-5"], "ep-4 is marked, so it's saved dismissed before auto-add looks")
        XCTAssertEqual(try states(subscription.id)["ep-4"], .dismissed)
    }

    func testAMarkTakenFromThePageAddressStillMatchesAnEntryThatNowHasAGUID() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        // Marked when the feed carried no GUID for it: the key is the page address.
        try await store.markItem(feedURL: feedURL, guid: nil, canonicalURL: "https://notforme.example/episodes/3", audioURL: nil, title: "Episode 3")
        let subscription = try await coordinator.follow(urlString: feedURL)
        XCTAssertEqual(try states(subscription.id)["ep-3"], .dismissed)
        XCTAssertEqual(try states(subscription.id)["ep-1"], .unseen)
    }

    func testTheMarkMatchesTheFeedWhateverTheSchemeHostCaseOrTrailingSlashItWasMarkedUnder() async throws {
        for spelling in ["http://notforme.example/feed.json", "HTTPS://NotForMe.Example/feed.json/", "https://notforme.example/feed.json#x"] {
            let store = NotForMeStore(fileURL: root.appendingPathComponent("marks-\(UUID().uuidString).json"))
            try await store.markItem(feedURL: spelling, guid: "ep-2", canonicalURL: nil, audioURL: nil, title: "Episode 2")
            let subscription = try await coordinator(marks: store.box).follow(urlString: feedURL)
            XCTAssertEqual(try states(subscription.id)["ep-2"], .dismissed, spelling)
            try await coordinator(marks: nil).unfollow(subscriptionId: subscription.id)
        }
    }

    func testAMarkOnAnotherFeedOrAnEpisodeTheListenerAlreadyAddedChangesNothing() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        try await store.markItem(feedURL: "https://elsewhere.example/feed.json", guid: "ep-1", canonicalURL: nil, audioURL: nil, title: "Other show")
        let subscription = try await coordinator.follow(urlString: feedURL)
        XCTAssertEqual(try states(subscription.id)["ep-1"], .unseen, "the same GUID on another show is not a mark here")

        // The listener adds episode 2, and a mark for it arrives later (a stale mark); it stays imported.
        let id = try XCTUnwrap(try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == "ep-2" }?.id)
        try await coordinator.setEntryState(id: id, state: .imported)
        try await store.markItem(feedURL: subscription.source.canonicalURL, guid: "ep-2", canonicalURL: nil, audioURL: nil, title: "Episode 2")
        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(try states(subscription.id)["ep-2"], .imported)
    }

    func testAnEpisodeUnmarkedByUndoComesBackOnTheNextRefresh() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        try await store.markItem(feedURL: feedURL, guid: "ep-2", canonicalURL: nil, audioURL: nil, title: "Episode 2")
        let subscription = try await coordinator.follow(urlString: feedURL)
        XCTAssertEqual(try states(subscription.id)["ep-2"], .dismissed)

        try await store.unmarkItem(feedURL: feedURL, guid: "ep-2", canonicalURL: nil, audioURL: nil)
        let id = try XCTUnwrap(try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == "ep-2" }?.id)
        try await coordinator.setEntryState(id: id, state: .unseen)   // what Undo does to the entry
        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(try states(subscription.id)["ep-2"], .unseen)
    }

    /// PR 6: the app marks through `markItem(_:of:)`, from the stored entry and its subscription. The mark it writes
    /// is the one the coordinator checks after unfollow and refollow; `unmarkItem(_:of:)` takes exactly that mark off.
    func testTheAppsMarkFromAStoredEntryAndItsSubscriptionSurvivesRefollowAndItsUndoClearsIt() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        let subscription = try await coordinator.follow(urlString: feedURL)
        let entry = try XCTUnwrap(try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == "ep-2" })
        _ = try await coordinator.dismissEntry(id: entry.id)
        try await store.markItem(entry, of: subscription)

        try await coordinator.unfollow(subscriptionId: subscription.id)
        let again = try await coordinator.follow(urlString: feedURL)
        XCTAssertEqual(try states(again.id)["ep-2"], .dismissed)

        try await store.unmarkItem(entry, of: subscription)
        let stored = await store.markedItems(feedKey: try XCTUnwrap(NotForMeStore.feedKey(for: feedURL)))
        XCTAssertTrue(stored.isEmpty)
    }

    /// Undo takes the mark off before it restores the entry. Restoring first and leaving the mark lets the next
    /// refresh dismiss the episode again, which is why the app's Undo runs in that order.
    func testUndoMustTakeTheMarkOffBeforeTheRefreshOrTheEpisodeIsDismissedAgain() async throws {
        let store = store()
        let coordinator = coordinator(marks: store.box)
        let subscription = try await coordinator.follow(urlString: feedURL)
        let entry = try XCTUnwrap(try repository.loadFeedEntries(subscriptionId: subscription.id).first { $0.episodeGUID == "ep-2" })
        let dismissedFrom = try await coordinator.dismissEntry(id: entry.id)
        let previous = try XCTUnwrap(dismissedFrom)
        try await store.markItem(entry, of: subscription)

        try await coordinator.undoDismissEntry(id: entry.id, restoring: previous)
        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(try states(subscription.id)["ep-2"], .dismissed, "with the mark still there, the refresh dismisses it again")

        // The app's order: the mark first, then the entry.
        try await store.unmarkItem(entry, of: subscription)
        try await coordinator.undoDismissEntry(id: entry.id, restoring: previous)
        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(try states(subscription.id)["ep-2"], previous)
    }
}

/// A JSON feed of `episodeCount` episodes whose GUIDs are `ep-N` and whose pages are `/episodes/N`.
private final class NotForMeFeedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var episodeCount = 3

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "notforme.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let formatter = ISO8601DateFormatter()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let items = (1...Self.episodeCount).map { index in
            let date = formatter.string(from: base.addingTimeInterval(Double(index) * 86_400))
            return #"{"id":"ep-\#(index)","url":"https://notforme.example/episodes/\#(index)","title":"Episode \#(index)","date_published":"\#(date)","attachments":[{"url":"https://notforme.example/\#(index).mp3","mime_type":"audio/mpeg"}]}"#
        }
        let data = Data(#"{"version":"https://jsonfeed.org/version/1.1","title":"Not For Me Show","items":[\#(items.joined(separator: ","))]}"#.utf8)
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/feed+json", "Content-Length": "\(data.count)"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
