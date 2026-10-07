import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #810: a Substack post shared as a link imported as an article but never looked for the post's voiceover,
/// which only followed posts did.
final class SharedLinkVoiceoverTests: XCTestCase {
    private let canonical = URL(string: "https://captured.example/p/voiceover")!

    func testAPostWithACompletedVoiceoverGivesTheRecord() throws {
        let shared = URL(string: "https://captured.example/p/voiceover?r=2abc&utm_campaign=post&utm_medium=ios")!
        let audio = try XCTUnwrap(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: shared, itemId: "item-1"))
        XCTAssertEqual(audio, PublisherAudio(
            itemId: "item-1", audioURL: "https://recordings.example/voiceover.mp3", durationMs: 752_875,
            detectedFrom: "substack_post_voiceover"
        ))
    }

    func testTheSamePostMatchesWhateverTheCaseOfTheHostOrATrailingSlash() throws {
        let final = URL(string: "https://Captured.EXAMPLE/p/voiceover/#footnote-1")!
        XCTAssertNotNil(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: final, itemId: "item"))
    }

    func testATextOnlyPostGivesNothing() throws {
        let page = try Self.page().replacingOccurrences(of: #"has_voiceover\":true"#, with: #"has_voiceover\":false"#)
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: canonical, itemId: "item"))
    }

    func testAPodcastPostGivesNothing() throws {
        let page = try Self.page().replacingOccurrences(of: "newsletter", with: "podcast")
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: canonical, itemId: "item"))
    }

    func testAPageWhosePreloadsNameADifferentPostGivesNothing() throws {
        let elsewhere = URL(string: "https://captured.example/p/another-post")!
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: elsewhere, itemId: "item"))
        let otherPublication = URL(string: "https://other.example/p/voiceover")!
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: try Self.page(), finalURL: otherPublication, itemId: "item"))
    }

    func testAPageWithoutPreloadsGivesNothing() {
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: "<html><p>Just text.</p></html>", finalURL: canonical, itemId: "item"))
    }

    func testTheFollowedPathReadsThePageTheSameWay() throws {
        let voiceover = try XCTUnwrap(PublisherNarrationEvidence.voiceover(inPostPage: try Self.page()))
        XCTAssertEqual(voiceover.canonicalURL, canonical.absoluteString)
        XCTAssertEqual(voiceover.audioURL, "https://recordings.example/voiceover.mp3")
        XCTAssertEqual(voiceover.durationMs, 752_875)
    }

    /// Neighbouring addresses (#810, #882): Substack hosts and a `/p/<slug>` post path on any host are worth one
    /// fetch; anything else is not.
    func testSubstackAddressesAndPostPathsOnAnyDomainAreFetched() {
        for yes in [
            "https://open.substack.com/pub/garymarcus/p/breaking?r=2abc&utm_medium=ios",
            "https://garymarcus.substack.com/p/breaking",
            "https://substack.com/home/post/p-123",
            "https://GaryMarcus.Substack.com/p/breaking",
            // A publication on its own domain, as the Substack app shared it on the owner's phone (2026-10-05).
            "https://victory.forwardblue.org/p/the-only-path-to-progress-is-fixing?r=4x1y&utm_medium=ios&triedRedirect=true",
            "https://www.platformer.news/p/breaking",
            "https://www.platformer.news/p/breaking/",
            "https://WWW.Platformer.NEWS/p/breaking#footnote-1",
            "https://example.com/p/%E2%9C%93-unicode-slug"
        ] {
            XCTAssertTrue(PublisherNarrationEvidence.mayHaveVoiceover(URL(string: yes)!), yes)
        }
        for no in [
            "http://garymarcus.substack.com/p/breaking",
            "http://www.platformer.news/p/breaking",
            "https://evilsubstack.com/article",
            "https://substack.com.evil.example/article",
            "https://example.com/article",
            "https://example.com/p/",
            "https://example.com/p",
            "https://example.com/p/breaking/comments",
            "https://example.com/blog/p/breaking",
            "https://example.com/P/breaking",
            "https://example.com/?p=123"
        ] {
            XCTAssertFalse(PublisherNarrationEvidence.mayHaveVoiceover(URL(string: no)!), no)
        }
    }

    /// The owner's phone, 2026-10-05: a post on its own domain, shared from the Substack app, was read with
    /// on-device speech because only `substack.com` addresses were looked up. The resolver had already read the
    /// page, so the voiceover is found with no further request.
    func testACustomDomainPostSharedFromTheSubstackAppFindsItsVoiceover() async throws {
        let shared = URL(string: "https://captured.example/p/voiceover?r=4x1y&utm_campaign=post&utm_medium=ios&triedRedirect=true")!
        let fetched = FetchedPageMemo()
        fetched.remember(Data(try Self.page().utf8), for: shared)
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: shared, articleURL: shared.absoluteString, itemId: "item", fetched: fetched,
            fetchPage: { _ in XCTFail("the resolver's page is the answer"); throw URLError(.badURL) }
        )
        XCTAssertEqual(outcome, .found(PublisherAudio(
            itemId: "item", audioURL: "https://recordings.example/voiceover.mp3", durationMs: 752_875,
            detectedFrom: "substack_post_voiceover"
        )))
    }

    func testACustomDomainPostTheResolverDidNotReadIsFetchedOnce() async throws {
        let requests = RequestLog()
        let page = try Self.page()
        let shared = URL(string: "https://captured.example/p/voiceover?r=4x1y&utm_medium=ios")!
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: shared, articleURL: "https://captured.example/p/voiceover", itemId: "item", fetched: FetchedPageMemo(),
            fetchPage: { url in requests.append(url); return (page, URL(string: "https://captured.example/p/voiceover")!) }
        )
        guard case .found = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(requests.urls, [shared])
    }

    /// A shared address that isn't a post path (a short link the resolver followed to the post) is still read when
    /// the page it ended at declares Substack's `_preloads`, without another request.
    func testARememberedPageDeclaringPreloadsIsReadWhateverItsAddress() async throws {
        let short = URL(string: "https://captured.example/s/abc")!
        let fetched = FetchedPageMemo()
        fetched.remember(Data(try Self.page().utf8), for: short, finalURL: URL(string: "https://captured.example/p/voiceover")!)
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: short, articleURL: "https://captured.example/p/voiceover", itemId: "item", fetched: fetched,
            fetchPage: { _ in XCTFail("the remembered page is the answer"); throw URLError(.badURL) }
        )
        guard case .found = outcome else { return XCTFail("\(outcome)") }
    }

    func testAnOrdinaryArticleTheResolverReadIsNeitherReadNorFetched() async {
        let article = URL(string: "https://openai.com/index/some-research")!
        let fetched = FetchedPageMemo()
        fetched.remember(Data("<html><p>Research.</p></html>".utf8), for: article)
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: article, articleURL: article.absoluteString, itemId: "item", fetched: fetched,
            fetchPage: { _ in XCTFail("no fetch for an ordinary article"); throw URLError(.badURL) }
        )
        XCTAssertEqual(outcome, .notSubstack)
    }

    /// A `/p/<slug>` page on a site that isn't Substack (a Blogger page, say) is fetched but gives nothing.
    func testAPostPathPageWithoutAVoiceoverGivesNothing() async {
        let page = URL(string: "https://someblog.example/p/about")!
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: page, articleURL: page.absoluteString, itemId: "item", fetched: nil,
            fetchPage: { url in ("<html><p>About me.</p></html>", url) }
        )
        XCTAssertEqual(outcome, .none)
    }

    /// Codex audit on 749fc07: the share path fetched the post page for link resolution and then again for the
    /// voiceover. With the resolver's memo the lookup reads the page it already has: one request in all.
    func testTheSharedPostPageIsRequestedOnceForResolutionAndTheVoiceover() async throws {
        let page = Data(try Self.substackPage().utf8)
        let requests = RequestLog()
        let fetched = FetchedPageMemo()
        let post = substackPost
        let resolver = PublicPodcastLinkResolver(asynchronousFetch: { url in
            requests.append(url)
            guard url == post else { throw URLError(.notConnectedToInternet) }
            return page
        }).remembering(fetched)

        _ = try await resolver.resolveAsync(LinkResolutionRequest(id: "share", inputURL: substackPost.absoluteString, sourceSurface: "share_sheet", createdAt: Date()))
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: substackPost, articleURL: substackPost.absoluteString, itemId: "item", fetched: fetched,
            fetchPage: { url in requests.append(url); throw URLError(.notConnectedToInternet) }
        )

        XCTAssertEqual(outcome, .found(PublisherAudio(
            itemId: "item", audioURL: "https://recordings.example/voiceover.mp3", durationMs: 752_875,
            detectedFrom: "substack_post_voiceover"
        )))
        XCTAssertEqual(requests.urls.filter { $0 == substackPost }.count, 1, "post page requests: \(requests.urls)")
    }

    func testTheSynchronousResolverRemembersThePageItFetchedToo() throws {
        let requests = RequestLog()
        let fetched = FetchedPageMemo()
        let resolver = PublicPodcastLinkResolver(fetch: { url in
            requests.append(url)
            return Data("<html><head><title>Just text</title></head><body><p>Nothing to play.</p></body></html>".utf8)
        }).remembering(fetched)

        _ = try resolver.resolve(LinkResolutionRequest(id: "share", inputURL: substackShare.absoluteString, sourceSurface: "share_sheet", createdAt: Date()))

        XCTAssertEqual(requests.urls, [substackShare], "resolution reads the page once")
        XCTAssertNotNil(fetched.page(for: substackShare))
    }

    func testWithoutAMemoTheResolverStillFetchesEveryTime() throws {
        let requests = RequestLog()
        let resolver = PublicPodcastLinkResolver(fetch: { url in
            requests.append(url)
            return Data("<html><head><title>Just text</title></head><body></body></html>".utf8)
        })
        _ = try resolver.resolve(LinkResolutionRequest(id: "share", inputURL: substackShare.absoluteString, sourceSurface: "share_sheet", createdAt: Date()))
        XCTAssertGreaterThan(requests.urls.count, 1, "other callers keep fetching fresh pages")
    }

    func testThePageIsFetchedOnceWhenTheResolverDidNotReadIt() async {
        let requests = RequestLog()
        let page = (try? Self.page()) ?? ""
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: URL(string: "https://example.com/share")!, articleURL: substackShare.absoluteString, itemId: "item", fetched: FetchedPageMemo(),
            fetchPage: { url in requests.append(url); return (page, URL(string: "https://captured.example/p/voiceover")!) }
        )
        guard case .found = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(requests.urls, [substackShare])
    }

    func testAFailedFetchAndANonSubstackLinkAreReported() async {
        let failed = await SharedPostVoiceoverLookup.find(
            sharedURL: substackShare, articleURL: "", itemId: "item", fetched: nil,
            fetchPage: { _ in throw URLError(.notConnectedToInternet) }
        )
        guard case .failed = failed else { return XCTFail("\(failed)") }
        let elsewhere = await SharedPostVoiceoverLookup.find(
            sharedURL: URL(string: "https://example.com/a")!, articleURL: "https://example.com/a", itemId: "item", fetched: nil,
            fetchPage: { _ in XCTFail("no fetch for a non-Substack address"); throw URLError(.badURL) }
        )
        XCTAssertEqual(elsewhere, .notSubstack)
    }

    func testARememberedPageThatIsTooLargeOrNotHTTPSIsNotRead() async {
        let large = FetchedPageMemo()
        large.remember(Data(count: SharedPostVoiceoverLookup.maximumPageBytes + 1), for: substackShare)
        let insecure = FetchedPageMemo()
        insecure.remember(Data(((try? Self.page()) ?? "").utf8), for: substackShare, finalURL: URL(string: "http://captured.example/p/voiceover")!)
        for memo in [large, insecure] {
            let outcome = await SharedPostVoiceoverLookup.find(
                sharedURL: substackShare, articleURL: "", itemId: "item", fetched: memo,
                fetchPage: { _ in XCTFail("the remembered page is the answer"); throw URLError(.badURL) }
            )
            guard case .failed = outcome else { return XCTFail("\(outcome)") }
        }
    }

    private let substackShare = URL(string: "https://open.substack.com/pub/captured/p/voiceover")!
    private let substackPost = URL(string: "https://captured.substack.com/p/voiceover")!

    /// The fixture, as if its post lived on a Substack host (only those are looked up).
    private static func substackPage() throws -> String {
        try page().replacingOccurrences(of: "https://captured.example/p/voiceover", with: "https://captured.substack.com/p/voiceover")
    }

    private static func page() throws -> String {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        let url = root.appendingPathComponent("Contracts/fixtures/feeds/substack-voiceover-page.html")
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [URL] = []

    func append(_ url: URL) { lock.lock(); requested.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requested }
}
