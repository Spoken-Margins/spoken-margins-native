import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 10a: "Add everything new" leaves out what the listener's rules set aside. The coordinator takes the evaluator
/// as an injected closure; without one a refresh adds what it always did.
final class FollowedSourceSetAsideTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SetAsideFeedURLProtocol.titles = [1: "Garden notes", 2: "Maps and more"]
    }

    private func coordinator(
        _ repository: InMemorySessionRepository, setAside: FollowedSourceCoordinator.SetAside?
    ) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SetAsideFeedURLProtocol.self]
        return FollowedSourceCoordinator(
            repository: repository, session: URLSession(configuration: configuration), setAside: setAside, signals: nil)
    }

    /// Follows the feed with "Add every new item" on and two back-catalogue episodes stored.
    private func follow(_ coordinator: FollowedSourceCoordinator) async throws -> FeedSubscription {
        let subscription = try await coordinator.follow(urlString: "https://setaside.example/feed.json")
        try await coordinator.setNewItemPolicy(subscriptionId: subscription.id, policy: .addEveryNewItem)
        return subscription
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(entryIds: Set<String>, subscriptionId: String)] = []
        func record(_ entries: [FeedEntry], _ subscription: FeedSubscription) {
            lock.withLock { seen.append((Set(entries.map(\.title)), subscription.id)) }
        }
        var all: [(entryIds: Set<String>, subscriptionId: String)] { lock.withLock { seen } }
    }

    func testAnEpisodeTheClosureSetsAsideIsNotAddedButStaysInFollowing() async throws {
        let repository = InMemorySessionRepository()
        let calls = Calls()
        let coordinator = coordinator(repository, setAside: { entries, subscription in
            calls.record(entries, subscription)
            return Set(entries.filter { $0.title.localizedCaseInsensitiveContains("crypto") }.map(\.id))
        })
        let subscription = try await follow(coordinator)
        SetAsideFeedURLProtocol.titles = [1: "Garden notes", 2: "Maps and more", 3: "Crypto weekly", 4: "Weather today"]
        let added = await coordinator.refreshStale(force: true)
        XCTAssertEqual(added.map(\.title).sorted(), ["Weather today"], "the crypto episode is set aside")
        let stored = try await coordinator.entries()
        let skipped = try XCTUnwrap(stored.first { $0.title == "Crypto weekly" })
        XCTAssertEqual(skipped.state, .unseen, "it waits in Following, not dismissed")
        // The closure saw the show's whole stored list, the back catalogue included, so a rule's guard can read the window.
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(calls.all[0].subscriptionId, subscription.id)
        XCTAssertEqual(calls.all[0].entryIds, ["Garden notes", "Maps and more", "Crypto weekly", "Weather today"])
    }

    func testNoClosureAddsWhatItAlwaysDid() async throws {
        let coordinator = coordinator(InMemorySessionRepository(), setAside: nil)
        _ = try await follow(coordinator)
        SetAsideFeedURLProtocol.titles = [1: "Garden notes", 2: "Maps and more", 3: "Crypto weekly"]
        let added = await coordinator.refreshStale(force: true)
        XCTAssertEqual(added.map(\.title), ["Crypto weekly"])
    }

    func testAnEmptyAnswerAddsEverything() async throws {
        let coordinator = coordinator(InMemorySessionRepository(), setAside: { _, _ in [] })
        _ = try await follow(coordinator)
        SetAsideFeedURLProtocol.titles = [1: "Garden notes", 2: "Maps and more", 3: "Crypto weekly"]
        let added = await coordinator.refreshStale(force: true)
        XCTAssertEqual(added.map(\.title), ["Crypto weekly"])
    }

    func testTheClosureIsNotAskedWhenThereIsNothingToAdd() async throws {
        let calls = Calls()
        let coordinator = coordinator(InMemorySessionRepository(), setAside: { entries, subscription in
            calls.record(entries, subscription)
            return []
        })
        _ = try await follow(coordinator)
        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(calls.all.count, 0, "no new episode, so no evaluation")
    }

    func testTheRealEvaluatorSetsAsideWhatARuleSkips() async throws {
        let rule = ListeningRule(id: "r", action: .skip, words: ["crypto"], isOn: true)
        let coordinator = coordinator(InMemorySessionRepository(), setAside: { entries, subscription in
            FollowingRuleEvaluation.setAside(entries: entries, subscription: subscription, inputs: FollowingRuleInputs(rules: [rule]))
        })
        _ = try await follow(coordinator)
        SetAsideFeedURLProtocol.titles = [1: "Garden notes", 2: "Maps and more", 3: "Crypto weekly", 4: "Weather today"]
        let added = await coordinator.refreshStale(force: true)
        XCTAssertEqual(added.map(\.title), ["Weather today"])
    }
}

/// A JSON feed whose episode titles each test sets, by number.
private final class SetAsideFeedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var titles: [Int: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "setaside.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let items = Self.titles.keys.sorted().map { n in
            """
            {"id":"episode-\(n)","url":"https://setaside.example/episodes/\(n)","title":"\(Self.titles[n] ?? "")","date_published":"2026-09-\(String(format: "%02d", n))T12:00:00Z","attachments":[{"url":"https://setaside.example/episode-\(n).mp3","mime_type":"audio/mpeg"}]}
            """
        }.joined(separator: ",")
        let data = Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"Set Aside Show","items":[\(items)]}
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
