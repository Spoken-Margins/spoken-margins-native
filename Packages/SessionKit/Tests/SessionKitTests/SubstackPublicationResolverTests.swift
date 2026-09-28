import CryptoKit
import Foundation
import XCTest
@testable import SessionKitFeeds

/// B2 M1: Follow didn't work for tracked links, old posts, large pages, share links, apex
/// domains or profiles. Replays research/B2's recorded responses; never touches the network.
final class SubstackPublicationResolverTests: XCTestCase {
    private static let research = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SessionKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // SessionKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo
        .appending(path: "research/B2", directoryHint: .isDirectory)
    private static let publicPodcast = "https://api.substack.com/feed/podcast/69345.rss"
    /// The shape of the link a paid subscriber copies from Substack; the token here is fake.
    private static let fakePrivate = "https://api.substack.com/feed/podcast/69345/private/0f0f0f0f-test-not-a-token.rss"

    private struct Case: Decodable {
        let id: String
        let category: String
        let url: String
        let expect_feed: String?
    }

    private func cases() throws -> [Case] {
        struct File: Decodable { let cases: [Case] }
        let data = try Data(contentsOf: Self.research.appending(path: "urls.json"))
        return try JSONDecoder().decode(File.self, from: data).cases
    }

    func testCommittedListHasAtLeastThirtySubstackLinksAcrossEveryShape() throws {
        let substack = try cases().filter { $0.expect_feed != nil }
        XCTAssertGreaterThanOrEqual(substack.count, 30)
        let categories = substack.map(\.category).joined(separator: " ")
        for needed in ["tracking", "old post", "home page", "/feed link", "share link", "profile"] {
            XCTAssertTrue(categories.contains(needed), needed)
        }
        XCTAssertTrue(substack.contains { !$0.url.contains("substack.com") }, "custom domains")
    }

    func testEveryRecordedLinkResolvesToItsPublicationFeed() async throws {
        let fetcher = ReplayFetcher(fixtures: Self.research.appending(path: "fixtures"))
        let resolver = SubstackPublicationResolver(fetch: fetcher.fetch)
        var failures: [String: String] = [:]
        for testCase in try cases() {
            let resolved = await resolver.resolve(testCase.url)
            if resolved?.feedURL != testCase.expect_feed {
                failures[testCase.id] = "expected \(testCase.expect_feed ?? "nil"), got \(resolved?.feedURL ?? "nil")"
            }
        }
        XCTAssertEqual(failures, [:])
        XCTAssertEqual(fetcher.misses, [], "every request was recorded")
    }

    func testOldAndTrackedPostsResolveWithoutBeingInTheFeed() async throws {
        let resolver = SubstackPublicationResolver(fetch: ReplayFetcher(fixtures: Self.research.appending(path: "fixtures")).fetch)
        for link in [
            "https://www.astralcodexten.com/p/spring-meetups-in-seventy-cities",
            "https://garymarcus.substack.com/p/promises-are-cheap?utm_source=substack&utm_medium=email",
            "https://www.astralcodexten.com/p/the-specter-of-neuralese?utm_source=substack&utm_medium=email&utm_content=share"
        ] {
            let resolved = await resolver.resolve(link)
            XCTAssertEqual(resolved?.kind, .publication, link)
            XCTAssertEqual(resolved?.isCertain, true, link)
            XCTAssertFalse(resolved?.feed.items.isEmpty ?? true, link)
        }
    }

    func testProfileCandidatesAreNeverPresentedAsCertain() async throws {
        let resolver = SubstackPublicationResolver(fetch: ReplayFetcher(fixtures: Self.research.appending(path: "fixtures")).fetch)
        // lennysnewsletter.substack.com redirects to an unrelated person's profile.
        let trap = await resolver.resolve("https://lennysnewsletter.substack.com/")
        XCTAssertEqual(trap?.feedURL, "https://na12.substack.com/feed")
        XCTAssertEqual(trap?.isCertain, false)
        XCTAssertTrue(trap?.reason.contains("profile") ?? false)
    }

    func testNonSubstackSitesAreLeftToGenericDiscoveryAfterOneRequest() async throws {
        let fetcher = ReplayFetcher(fixtures: Self.research.appending(path: "fixtures"))
        let resolver = SubstackPublicationResolver(fetch: fetcher.fetch)
        let resolved = await resolver.resolve("https://www.platformer.news/")
        XCTAssertNil(resolved)
        XCTAssertEqual(fetcher.requests, ["feed https://www.platformer.news/feed"], "one feed request (redirects included), no page download")
        let notes = await resolver.resolve("https://substack.com/notes")
        XCTAssertNil(notes, "a Substack app page that isn't a publication")
    }

    func testPrivateFeedLinkBecomesAPrivateCandidateWithoutLeakingItsToken() async throws {
        XCTAssertTrue(SubstackPublicationResolver.isPrivateFeedURL(Self.fakePrivate))
        XCTAssertFalse(SubstackPublicationResolver.isPrivateFeedURL(Self.publicPodcast))
        XCTAssertFalse(SubstackPublicationResolver.isPrivateFeedURL("https://www.astralcodexten.com/feed"))
        XCTAssertFalse(SubstackPublicationResolver.redact(Self.fakePrivate).contains("test-not-a-token"))

        let fetcher = ReplayFetcher(fixtures: Self.research.appending(path: "fixtures"), aliases: [Self.fakePrivate: Self.publicPodcast])
        let resolved = await SubstackPublicationResolver(fetch: fetcher.fetch).resolve(Self.fakePrivate)
        XCTAssertEqual(resolved?.kind, .privateFeed)
        XCTAssertEqual(resolved?.isPrivate, true)
        XCTAssertGreaterThan(resolved?.feed.items.filter { $0.audioURL != nil }.count ?? 0, 0)
        XCTAssertFalse(resolved?.reason.contains("test-not-a-token") ?? true)
    }

    func testStripTrackingKeepsMeaningfulQuery() {
        XCTAssertEqual(
            SubstackPublicationResolver.stripTracking("https://x.com/p/a?utm_source=s&r=1&page=2#f"),
            "https://x.com/p/a?page=2"
        )
        XCTAssertEqual(SubstackPublicationResolver.stripTracking("https://x.com/p/a?utm_medium=email"), "https://x.com/p/a")
    }
}

/// Replays research/B2/fixtures: one JSON per request hop, named sha256("<kind> <url>")[:16].
/// Follows redirects hop by hop like the app's `BoundedRedirectDelegate` (five at most, https only).
private final class ReplayFetcher: @unchecked Sendable {
    private let fixtures: URL
    private let aliases: [String: String]
    private let lock = NSLock()
    private var recordedRequests: [String] = []
    private var recordedMisses: [String] = []

    init(fixtures: URL, aliases: [String: String] = [:]) {
        self.fixtures = fixtures
        self.aliases = aliases
    }

    var requests: [String] { lock.withLock { recordedRequests } }
    var misses: [String] { lock.withLock { recordedMisses } }

    private struct Hop: Decodable {
        let url: String
        let status: Int
        let headers: [String: String]
        let body: String
    }

    struct Miss: Error {}
    struct RedirectRefused: Error {}

    var fetch: SubstackPublicationResolver.Fetch {
        { [self] url, kind in try self.get(url, kind) }
    }

    private func get(_ url: URL, _ kind: SubstackFetchKind) throws -> SubstackFetchResponse {
        lock.withLock { recordedRequests.append("\(kind.rawValue) \(url.absoluteString)") }
        var current = url.absoluteString
        for _ in 0...5 {
            let hop = try self.hop(current, kind)
            if [301, 302, 303, 307, 308].contains(hop.status), let location = hop.headers["location"] {
                guard let next = URL(string: location, relativeTo: URL(string: current))?.absoluteURL.absoluteString,
                      next.lowercased().hasPrefix("https://") else { throw RedirectRefused() }
                current = next
                continue
            }
            return SubstackFetchResponse(url: URL(string: current)!, status: hop.status, headers: hop.headers, body: Data(hop.body.utf8))
        }
        throw RedirectRefused()
    }

    private func hop(_ url: String, _ kind: SubstackFetchKind) throws -> Hop {
        let key = "\(kind.rawValue) \(aliases[url] ?? url)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let file = fixtures.appending(path: "\(digest).json")
        guard let data = try? Data(contentsOf: file) else {
            lock.withLock { recordedMisses.append(key) }
            throw Miss()
        }
        return try JSONDecoder().decode(Hop.self, from: data)
    }
}
