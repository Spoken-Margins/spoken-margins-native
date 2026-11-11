import Foundation
import XCTest
@testable import SessionKit

/// #3767 Done-when 6: a link list read twice must not add an episode twice. The item id is a hash of the
/// episode's audio address, so a repeated link, and two links that resolve to one episode, stay one item.
final class PodcastLinkImportedTwiceTests: XCTestCase {
    private struct StaticResolver: LinkResolutionClient {
        var result: LinkResolutionResult
        func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult { result }
    }

    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
    )

    private func candidate(audio: String, title: String = "Episode Title") -> LinkResolutionCandidate {
        LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", title: "Example Show", role: "canonical_feed"),
            title: title,
            showTitle: "Example Show",
            durationMs: 1_800_000,
            publishedAt: "2026-06-19",
            audioURL: audio,
            confidence: 0.96
        )
    }

    private func importLink(
        _ url: String, provider: String, candidate: LinkResolutionCandidate,
        at second: TimeInterval, into repo: InMemorySessionRepository
    ) throws -> String {
        let request = LinkResolutionRequest(
            id: "link-request-\(Int(second))", inputURL: url, sourceSurface: "link_list",
            createdAt: Date(timeIntervalSince1970: second)
        )
        let resolver = StaticResolver(result: LinkResolutionResult(
            requestId: request.id, status: .playable,
            originalLink: SourceLink(url: url, provider: provider, role: "discovery"),
            selectedCandidate: candidate, candidates: [candidate]
        ))
        let engine = SessionEngine(profile: profile, repository: repo, linkResolver: resolver)
        return try XCTUnwrap(try engine.importSourceLink(request).itemId)
    }

    func testTheSameEpisodeLinkTwiceAndTwoLinksToOneEpisodeStayOneItem() throws {
        let repo = InMemorySessionRepository()
        let episode = candidate(audio: "https://cdn.example.com/episode.mp3")
        let apple = "https://podcasts.apple.com/us/podcast/example/id1?i=2"

        let first = try importLink(apple, provider: "apple_podcasts", candidate: episode, at: 1, into: repo)
        let sameLinkAgain = try importLink(apple, provider: "apple_podcasts", candidate: episode, at: 2, into: repo)
        let otherLink = try importLink("https://open.spotify.com/episode/example", provider: "spotify", candidate: episode, at: 3, into: repo)

        XCTAssertEqual(sameLinkAgain, first)
        XCTAssertEqual(otherLink, first)
        XCTAssertEqual(try repo.listItems(includeDeleted: true).count, 1, "one episode, one Library row")
        XCTAssertEqual(try repo.loadItem(id: first).createdAt, Date(timeIntervalSince1970: 1), "the first import's record is kept")
    }

    /// The control: the guard above must not merge different episodes, including two with the same file name
    /// on a CDN (the identity is the whole address, query included).
    func testDifferentEpisodesStayTwoItems() throws {
        let repo = InMemorySessionRepository()
        let one = try importLink(
            "https://example.com/ep/1", provider: "rss",
            candidate: candidate(audio: "https://cdn.example.com/a/default.mp3?id=1", title: "One"), at: 1, into: repo)
        let two = try importLink(
            "https://example.com/ep/2", provider: "rss",
            candidate: candidate(audio: "https://cdn.example.com/a/default.mp3?id=2", title: "Two"), at: 2, into: repo)

        XCTAssertNotEqual(one, two)
        XCTAssertEqual(try repo.listItems(includeDeleted: true).count, 2)
    }
}
