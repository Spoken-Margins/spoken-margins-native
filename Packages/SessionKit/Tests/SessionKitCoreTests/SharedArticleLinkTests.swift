import Foundation
import XCTest
import SessionKit
import SessionKitFeeds

/// #223: a Substack post shared from the Substack app arrives as a bare link. It must be read as an article,
/// not quarantined and not imported as a podcast. Replays research/B2's recorded page and feed; never touches the
/// network.
final class SharedArticleLinkTests: XCTestCase {
    private static let postURL = "https://garymarcus.substack.com/p/breaking-ai-agent-incident-toll-has"
    private static let feedURL = "https://garymarcus.substack.com/feed"

    /// Substack's feed lists each text post with its cover image as an `image/jpeg` enclosure. The resolver took
    /// that picture for the episode audio, so the shared post came back "playable" with a JPEG as its audio.
    func testSubstackTextPostIsAPageWithNoAudio() throws {
        let result = try PublicPodcastLinkResolver(fetch: try Self.recorded()).resolve(Self.request())

        XCTAssertNotEqual(result.status, .playable, "audio: \(result.selectedCandidate?.audioURL ?? "none")")
        XCTAssertTrue(result.foundNoAudio, "\(result.status) \(result.failureReason ?? "no reason")")
    }

    /// J2: a Substack podcast post, whose feed item carries an audio enclosure, still resolves as a podcast first.
    func testSubstackPodcastPostStillResolvesAsAudio() throws {
        let feed = try Self.fixture("538bf67e312c6eb3").replacingOccurrences(
            of: #"<link>\#(Self.postURL)</link>"#,
            with: #"<link>\#(Self.postURL)</link><enclosure url="https://api.substack.com/feed/podcast/1/episode.mp3" length="1" type="audio/mpeg"/>"#
        )
        let result = try PublicPodcastLinkResolver(fetch: try Self.recorded(feed: feed)).resolve(Self.request())

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://api.substack.com/feed/podcast/1/episode.mp3")
        XCTAssertFalse(result.foundNoAudio)
    }

    @MainActor
    func testPageWithNoAudioIsReadByTheExtractor() async throws {
        let extractor = StubExtractor(.success(Self.article))
        var recorded: [String] = []

        let article = try await LinkArticleFallback.article(
            for: URL(string: Self.postURL)!, after: Self.noAudio, startSession: false, using: extractor,
            record: { recorded.append($0) }
        )

        XCTAssertEqual(extractor.requested, [URL(string: Self.postURL)!])
        XCTAssertEqual(article?.source.title, "BREAKING: AI agent incident toll has risen to tens of thousands")
        XCTAssertEqual(article?.requestedContinuation.startSession, false)
        XCTAssertEqual(recorded, ["defuddle"])
    }

    @MainActor
    func testUnreadablePageThrowsAnErrorNamingTheExtractorFailure() async throws {
        let extractor = StubExtractor(.failure(StubExtractor.Failure()))
        var recorded: [String] = []

        do {
            _ = try await LinkArticleFallback.article(
                for: URL(string: Self.postURL)!, after: Self.noAudio, startSession: false, using: extractor,
                record: { recorded.append($0) }
            )
            XCTFail("An unreadable page must not import.")
        } catch let error as LinkArticleFallbackError {
            XCTAssertEqual(error.extractorFailure, "No readable article text was found.")
            XCTAssertTrue(error.extractorError is StubExtractor.Failure, "the extractor's own error is kept so the app can offer Safari (#145)")
            XCTAssertTrue(error.localizedDescription.contains("No readable article text was found."), error.localizedDescription)
        }
        XCTAssertEqual(recorded, ["failed:No readable article text was found."])
    }

    @MainActor
    func testAudioOrPlainHTTPLinksAreNotReadAsArticles() async throws {
        let extractor = StubExtractor(.success(Self.article))
        var playable = Self.noAudio
        playable.status = .playable
        playable.failureReason = nil
        var review = Self.noAudio
        review.failureReason = "rss_episode_ambiguous"

        for (link, result) in [(Self.postURL, playable), (Self.postURL, review), ("http://example.com/p/post", Self.noAudio)] {
            let article = try await LinkArticleFallback.article(
                for: URL(string: link)!, after: result, startSession: false, using: extractor, record: { _ in }
            )
            XCTAssertNil(article, "\(link) \(result.status)")
        }
        XCTAssertEqual(extractor.requested, [])
    }

    private static let noAudio = LinkResolutionResult(
        requestId: "shared",
        status: .needsReview,
        originalLink: SourceLink(url: postURL, provider: "garymarcus.substack.com", role: "discovery"),
        selectedCandidate: nil,
        failureReason: "audio_enclosure_not_found"
    )

    private static let article = BrowserTextHandoff(
        captureMode: .readablePage,
        source: BrowserTextSource(url: postURL, title: "BREAKING: AI agent incident toll has risen to tens of thousands"),
        text: "# BREAKING: AI agent incident toll has risen to tens of thousands\n\nThe post's body.",
        contentFormat: .markdown,
        requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "app")
    )

    private static func request() -> LinkResolutionRequest {
        LinkResolutionRequest(id: "shared", inputURL: postURL, sourceSurface: "share_sheet", createdAt: Date())
    }

    /// The post page and its publication feed, as research/B2 recorded them. Any other request fails, as offline.
    private static func recorded(feed: String? = nil) throws -> PublicPodcastLinkResolver.Fetch {
        let page = Data(try fixture("ceae4ceedeedc0e9").utf8)
        let feed = Data(try (feed ?? fixture("538bf67e312c6eb3")).utf8)
        return { url in
            switch url.absoluteString {
            case postURL: return page
            case feedURL: return feed
            default: throw URLError(.notConnectedToInternet)
            }
        }
    }

    private static func fixture(_ name: String) throws -> String {
        struct Hop: Decodable { let body: String }
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SessionKitCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SessionKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo
            .appendingPathComponent("research/B2/fixtures/\(name).json")
        return try JSONDecoder().decode(Hop.self, from: Data(contentsOf: file)).body
    }
}

@MainActor
private final class StubExtractor: ReadablePageExtracting {
    struct Failure: LocalizedError {
        var errorDescription: String? { "No readable article text was found." }
    }

    private let outcome: Result<BrowserTextHandoff, Error>
    private(set) var requested: [URL] = []
    private(set) var lastExtractor: String?
    private(set) var contactedHosts: [String] = []

    init(_ outcome: Result<BrowserTextHandoff, Error>) {
        self.outcome = outcome
    }

    func extract(url: URL) async throws -> BrowserTextHandoff {
        requested.append(url)
        contactedHosts = [url.host ?? ""]
        let handoff = try outcome.get()
        lastExtractor = "defuddle"
        return handoff
    }
}
