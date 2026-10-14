import Foundation
import XCTest
@testable import SessionKit

final class PodcastNameSearchTests: XCTestCase {
    private static func body(_ titles: [String]) -> Data {
        let results = titles.enumerated().map { index, title in
            #"{"collectionId":\#(index + 1),"collectionName":"\#(title)","artistName":"Studio","feedUrl":"https://example.com/\#(index + 1).xml"}"#
        }.joined(separator: ",")
        return Data(#"{"resultCount":\#(titles.count),"results":[\#(results)]}"#.utf8)
    }

    private actor Log {
        var terms: [String] = []
        func record(_ url: URL) {
            let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value
            terms.append(term ?? "")
        }
    }

    private func searcher(
        pause: Duration = .milliseconds(30),
        log: Log = Log(),
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        answer: @escaping @Sendable (String) async throws -> Data
    ) -> PodcastNameSearch {
        let resolver = ITunesSearchSourceResolver { url, _ in
            await log.record(url)
            let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "term" }?.value ?? ""
            return (200, try await answer(term))
        }
        if let sleep { return PodcastNameSearch(resolver: resolver, pause: pause, sleep: sleep) }
        return PodcastNameSearch(resolver: resolver, pause: pause)
    }

    func testAMatchingShowComesFirst() async throws {
        let search = searcher { _ in Self.body(["Hard Fork", "Fork Lore"]) }
        let outcome = await search.search("hard fork")
        guard case .results(let shows)? = outcome else { return XCTFail("expected results, got \(String(describing: outcome))") }
        XCTAssertEqual(shows.first?.title, "Hard Fork")
        XCTAssertEqual(shows.first?.feed?.url, "https://example.com/1.xml")
    }

    func testAShowWithNoFeedIsListedWithItsReason() async throws {
        let data = Data(#"{"resultCount":1,"results":[{"collectionId":9,"collectionName":"Exclusive Show","artistName":"Studio"}]}"#.utf8)
        let outcome = await searcher { _ in data }.search("exclusive show")
        guard case .results(let shows)? = outcome else { return XCTFail("expected results") }
        XCTAssertNil(shows.first?.feed)
        XCTAssertEqual(shows.first?.reason, "No public feed: this show is exclusive to another app")
    }

    func testTooShortAQueryIsNotSearched() async {
        let log = Log()
        let search = searcher(log: log) { _ in Self.body(["X"]) }
        let one = await search.search("h")
        let blank = await search.search("   ")
        XCTAssertNil(one)
        XCTAssertNil(blank)
        let terms = await log.terms
        XCTAssertEqual(terms, [])
        XCTAssertFalse(PodcastNameSearch.isSearchable(" a "))
        XCTAssertTrue(PodcastNameSearch.isSearchable("ab"))
    }

    func testTypingOnDuringThePauseSearchesOnlyTheLastQuery() async throws {
        let log = Log()
        let firstPaused = expectation(description: "first query is paused")
        let secondPaused = expectation(description: "second query is paused")
        let gate = PauseGate(first: firstPaused, second: secondPaused)
        let search = searcher(log: log, sleep: { try await gate.sleep($0) }) { term in Self.body([term]) }
        async let first = search.search("hard")
        await fulfillment(of: [firstPaused], timeout: 5)
        async let second = search.search("hard fork")
        await fulfillment(of: [secondPaused], timeout: 5)
        await gate.release()
        let (a, b) = await (first, second)
        XCTAssertNil(a, "the superseded search returns nothing")
        guard case .results(let shows)? = b else { return XCTFail("expected results") }
        XCTAssertEqual(shows.first?.title, "hard fork")
        let terms = await log.terms
        XCTAssertEqual(terms, ["hard fork"], "one request, for the last query")
    }

    func testASlowAnswerForAnOlderQueryIsDropped() async throws {
        let log = Log()
        let search = searcher(pause: .milliseconds(10), log: log) { term in
            if term == "hard" { try await Task.sleep(for: .milliseconds(400)) }
            return Self.body([term])
        }
        async let older = search.search("hard")
        try await Task.sleep(for: .milliseconds(100))   // the request for "hard" is now out
        let newer = await search.search("hard fork")
        let stale = await older
        XCTAssertNil(stale, "the older answer arrived after a newer search and is dropped")
        guard case .results(let shows)? = newer else { return XCTFail("expected results") }
        XCTAssertEqual(shows.first?.title, "hard fork")
    }

    func testAFailureIsReportedInWordsAndTheNextSearchStillWorks() async throws {
        let failing = FlakyAnswer()
        let search = searcher { term in
            if await failing.shouldFail() { throw URLError(.notConnectedToInternet) }
            return Self.body([term])
        }
        let failed = await search.search("hard fork")
        XCTAssertEqual(failed, .failed(PodcastNameSearch.networkFailureMessage))
        let retried = await search.search("hard fork")
        guard case .results(let shows)? = retried else { return XCTFail("expected results") }
        XCTAssertEqual(shows.count, 1)
    }

    func testCancelDropsASearchThatIsWaiting() async throws {
        let log = Log()
        let paused = expectation(description: "query is paused")
        let gate = PauseGate(first: paused)
        let search = searcher(log: log, sleep: { try await gate.sleep($0) }) { term in Self.body([term]) }
        async let waiting = search.search("hard fork")
        await fulfillment(of: [paused], timeout: 5)
        await search.cancel()
        await gate.release()
        let result = await waiting
        XCTAssertNil(result)
        let terms = await log.terms
        XCTAssertEqual(terms, [])
    }

    private actor FlakyAnswer {
        private var calls = 0
        func shouldFail() -> Bool { calls += 1; return calls == 1 }
    }

    /// Establishes that the calls really overlap within the pause, without a wall-clock race.
    private actor PauseGate {
        private let first: XCTestExpectation
        private let second: XCTestExpectation?
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private var released = false

        init(first: XCTestExpectation, second: XCTestExpectation? = nil) {
            self.first = first
            self.second = second
        }

        func sleep(_ duration: Duration) async throws {
            guard !released else { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(continuation)
                if waiters.count == 1 { first.fulfill() }
                if waiters.count == 2 { second?.fulfill() }
            }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
