import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// A refresh of a feed set to "Add every new item" hands back only the episode published since the
/// last refresh, once; "Let me pick", a muted feed and the back catalogue at follow time hand back
/// nothing (#466). The model imports what comes back through `importFollowedSourceEntry`, the same
/// path as tapping Add, which marks the entry imported
/// (`SourceLinkImportTests.testFeedEntryImportPreservesTitleAndSourceWithoutChangingActivePlayback`).
final class FeedNewItemPolicyRefreshTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GrowingFeedURLProtocol.episodes = [1, 2]
    }

    private func coordinator(_ repository: InMemorySessionRepository) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrowingFeedURLProtocol.self]
        return FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: nil)
    }

    func testAddEveryNewItemReturnsTheNewEpisodeOnceAndNeverTheBackCatalogue() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        let subscription = try await coordinator.follow(urlString: "https://newitems.example/feed.json")
        try await coordinator.setNewItemPolicy(subscriptionId: subscription.id, policy: .addEveryNewItem)
        let unchanged = await coordinator.refreshStale(force: true)
        XCTAssertEqual(unchanged, [], "Episodes 1 and 2 were there at follow time")

        GrowingFeedURLProtocol.episodes = [1, 2, 3]
        let added = await coordinator.refreshStale(force: true)
        XCTAssertEqual(added.map(\.title), ["Episode 3"])
        XCTAssertEqual(added.first?.state, .unseen)
        let again = await coordinator.refreshStale(force: true)
        XCTAssertEqual(again, [], "A second refresh adds nothing")

        // Following the feed again keeps the choice.
        _ = try await coordinator.follow(urlString: "https://newitems.example/feed.json")
        XCTAssertEqual(try repository.loadFeedSubscriptions().first?.newItemPolicy, .addEveryNewItem)
    }

    func testLetMePickAndMutedFeedsAddNothing() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository)
        let subscription = try await coordinator.follow(urlString: "https://newitems.example/feed.json")
        XCTAssertNil(subscription.newItemPolicy, "New follows default to Let me pick")

        GrowingFeedURLProtocol.episodes = [1, 2, 3]
        let pick = await coordinator.refreshStale(force: true)
        XCTAssertEqual(pick, [])
        let waiting = try await coordinator.entries()
        XCTAssertTrue(waiting.contains { $0.title == "Episode 3" }, "It waits in Following")

        try await coordinator.setNewItemPolicy(subscriptionId: subscription.id, policy: .addEveryNewItem)
        try await coordinator.setMuted(subscriptionId: subscription.id, muted: true)
        GrowingFeedURLProtocol.episodes = [1, 2, 3, 4]
        let muted = await coordinator.refreshStale(force: true)
        XCTAssertEqual(muted, [])
    }
}

/// A JSON feed whose episode list each test sets.
private final class GrowingFeedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var episodes: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "newitems.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let items = Self.episodes.map { n in
            """
            {"id":"episode-\(n)","url":"https://newitems.example/episodes/\(n)","title":"Episode \(n)","date_published":"2026-09-\(String(format: "%02d", n))T12:00:00Z","attachments":[{"url":"https://newitems.example/episode-\(n).mp3","mime_type":"audio/mpeg"}]}
            """
        }.joined(separator: ",")
        let data = Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"Growing Show","items":[\(items)]}
        """.utf8)
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
