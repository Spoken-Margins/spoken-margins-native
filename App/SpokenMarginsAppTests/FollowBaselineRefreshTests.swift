import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #1589: following a feed with a large archive leaves its old episodes out of New, on the follow,
/// on every refresh, and after unfollowing and following again. The coordinator stamps the feed's
/// first fetch with the follow moment; `FollowBaseline` (SessionKit) decides from the stamp and the
/// publish date. One feed has dates, one has none.
final class FollowBaselineRefreshTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ArchiveFeedURLProtocol.newEpisodes = 0
    }

    private func coordinator(_ repository: InMemorySessionRepository) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveFeedURLProtocol.self]
        return FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: nil)
    }

    private func newTitles(_ coordinator: FollowedSourceCoordinator, _ repository: InMemorySessionRepository) async throws -> [String] {
        let candidates = QuickAddFeed.candidates(
            folderFiles: [],
            followedEntries: try await coordinator.entries(),
            subscriptions: try repository.loadFeedSubscriptions()
        )
        return candidates.compactMap { candidate in
            guard case .followedSource(let entry) = candidate else { return nil }
            return entry.title
        }.sorted()
    }

    func testALargeArchiveDoesNotFloodNewAndLaterEpisodesStillDo() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        _ = try await coordinator.follow(urlString: "https://archive.example/dated.json")
        let stored = try await coordinator.entries()
        XCTAssertEqual(stored.count, FollowedSourceCoordinator.maximumRetainedSuggestionsPerFeed, "the archive is kept, not deleted")
        let afterFollow = try await newTitles(coordinator, repository)
        XCTAssertEqual(afterFollow, [], "the back catalogue is not New")

        ArchiveFeedURLProtocol.newEpisodes = 1
        _ = await coordinator.refreshStale(force: true)
        let afterRefresh = try await newTitles(coordinator, repository)
        XCTAssertEqual(afterRefresh, ["Fresh 1"], "an episode published after the follow is New")
        _ = await coordinator.refreshStale(force: true)
        let afterAnother = try await newTitles(coordinator, repository)
        XCTAssertEqual(afterAnother, ["Fresh 1"], "a refresh does not bring the archive back")
    }

    func testUnfollowingAndFollowingAgainKeepsTheArchiveOut() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        let first = try await coordinator.follow(urlString: "https://archive.example/dated.json")
        ArchiveFeedURLProtocol.newEpisodes = 1
        _ = await coordinator.refreshStale(force: true)
        let beforeUnfollow = try await newTitles(coordinator, repository)
        XCTAssertEqual(beforeUnfollow, ["Fresh 1"])

        try await coordinator.unfollow(subscriptionId: first.id)
        _ = try await coordinator.follow(urlString: "https://archive.example/dated.json")
        let afterRefollow = try await newTitles(coordinator, repository)
        XCTAssertEqual(afterRefollow, [], "the new follow is the new baseline, even for an episode dated after it")
    }

    func testAFeedWithoutDatesDoesNotFloodNewEither() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        _ = try await coordinator.follow(urlString: "https://archive.example/undated.json")
        let afterFollow = try await newTitles(coordinator, repository)
        XCTAssertEqual(afterFollow, [])

        ArchiveFeedURLProtocol.newEpisodes = 1
        _ = await coordinator.refreshStale(force: true)
        let afterRefresh = try await newTitles(coordinator, repository)
        XCTAssertEqual(afterRefresh, ["Fresh 1"])
    }

    func testClearingNewDismissesTheListedEntriesAndUndoPutsThemBack() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        _ = try await coordinator.follow(urlString: "https://archive.example/dated.json")
        let ids = try await coordinator.entries().map(\.id)
        XCTAssertFalse(ids.isEmpty)

        let previous = try await coordinator.dismissEntries(ids: ids + ["missing"])
        XCTAssertEqual(Set(previous.keys), Set(ids), "an id with no entry is skipped")
        let afterClear = try await coordinator.entries()
        XCTAssertEqual(afterClear, [], "nothing is left to dismiss one by one")
        let again = try await coordinator.dismissEntries(ids: ids)
        XCTAssertTrue(again.isEmpty, "entries already dismissed keep the state Undo restores")

        try await coordinator.undoDismissEntries(restoring: previous)
        let restored = try await coordinator.entries().map(\.id)
        XCTAssertEqual(Set(restored), Set(ids))
    }
}

/// A JSON feed with a 40-episode archive, dated or not, and `newEpisodes` fresh episodes on top.
private final class ArchiveFeedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var newEpisodes = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "archive.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let dated = request.url?.lastPathComponent == "dated.json"
        let formatter = ISO8601DateFormatter()
        let day: TimeInterval = 86_400
        func item(_ id: String, title: String, date: Date) -> String {
            let published = dated ? #","date_published":"\#(formatter.string(from: date))""# : ""
            return #"{"id":"\#(id)","url":"https://archive.example/episodes/\#(id)","title":"\#(title)"\#(published),"attachments":[{"url":"https://archive.example/\#(id).mp3","mime_type":"audio/mpeg"}]}"#
        }
        let archive = (1...40).map { item("old-\($0)", title: "Old \($0)", date: Date().addingTimeInterval(-Double($0) * 7 * day)) }
        // Dated a day ahead so it is after the follow however slowly the test runs.
        let fresh = (0..<Self.newEpisodes).map { item("fresh-\($0 + 1)", title: "Fresh \($0 + 1)", date: Date().addingTimeInterval(day)) }
        let data = Data(#"{"version":"https://jsonfeed.org/version/1.1","title":"Archive Show","items":[\#((fresh + archive).joined(separator: ","))]}"#.utf8)
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
