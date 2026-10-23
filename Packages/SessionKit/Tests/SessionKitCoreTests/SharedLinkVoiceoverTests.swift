import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #810: a Substack post shared as a link imported as an article but never looked for the post's voiceover,
/// which only followed posts did.
final class SharedLinkVoiceoverTests: XCTestCase {
    private let canonical = URL(string: "https://captured.example/p/voiceover")!

    func testAPostWithACompletedVoiceoverGivesTheRecord() throws {
        let shared = URL(string: "https://captured.example/p/voiceover?r=2abc&utm_campaign=post&utm_medium=ios")!
        let page = try Self.page()
        let audio = try XCTUnwrap(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: shared, itemId: "item-1"))
        XCTAssertEqual(audio, PublisherAudio(
            itemId: "item-1", audioURL: "https://recordings.example/voiceover.mp3", durationMs: 752_875,
            detectedFrom: "substack_post_voiceover"
        ))
    }

    func testTheSamePostMatchesWhateverTheCaseOfTheHostOrATrailingSlash() throws {
        let final = URL(string: "https://Captured.EXAMPLE/p/voiceover/#footnote-1")!
        let page = try Self.page()
        XCTAssertNotNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: final, itemId: "item"))
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
        let page = try Self.page()
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: elsewhere, itemId: "item"))
        let otherPublication = URL(string: "https://other.example/p/voiceover")!
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: otherPublication, itemId: "item"))
    }

    func testAPageWithoutPreloadsGivesNothing() {
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: "<html><p>Just text.</p></html>", finalURL: canonical, itemId: "item"))
    }

    func testTheFollowedPathReadsThePageTheSameWay() throws {
        let page = try Self.page()
        let voiceover = try XCTUnwrap(PublisherNarrationEvidence.voiceover(inPostPage: page))
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
        XCTAssertEqual(outcome, .noVoiceover(reason: "no_preloads"))
    }

    /// The owner's export could only show the last share (an openai.com link, `not_substack`), not what happened
    /// to the Substack post shared before it. The log keeps each item's latest outcome.
    func testTheLogKeepsEachSharedItemsLatestOutcome() {
        var log = SharedPostVoiceoverLog()
        log.record("none", for: "item-a")
        log.record("saved", for: "item-b")
        log.record("not_substack", for: "item-c")
        log.record("text map 40%", for: "item-b")
        XCTAssertEqual(log.summary, "item-a: none; item-c: not_substack; item-b: text map 40%")
    }

    func testTheLogKeepsOnlyTheMostRecentItems() {
        var log = SharedPostVoiceoverLog()
        for index in 0..<(SharedPostVoiceoverLog.capacity + 3) { log.record("none", for: "item-\(index)") }
        let lines = log.summary.components(separatedBy: "; ")
        XCTAssertEqual(lines.count, SharedPostVoiceoverLog.capacity)
        XCTAssertEqual(lines.first, "item-3: none")
        XCTAssertEqual(lines.last, "item-\(SharedPostVoiceoverLog.capacity + 2): none")
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

    func testThePageIsFetchedOnceWhenTheResolverDidNotReadIt() async throws {
        let requests = RequestLog()
        let page = try Self.page()
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

    func testARememberedPageThatIsTooLargeOrNotHTTPSIsNotRead() async throws {
        let large = FetchedPageMemo()
        large.remember(Data(count: SharedPostVoiceoverLookup.maximumPageBytes + 1), for: substackShare)
        let insecure = FetchedPageMemo()
        insecure.remember(Data(try Self.page().utf8), for: substackShare, finalURL: URL(string: "http://captured.example/p/voiceover")!)
        for memo in [large, insecure] {
            let outcome = await SharedPostVoiceoverLookup.find(
                sharedURL: substackShare, articleURL: "", itemId: "item", fetched: memo,
                fetchPage: { _ in XCTFail("the remembered page is the answer"); throw URLError(.badURL) }
            )
            guard case .failed = outcome else { return XCTFail("\(outcome)") }
        }
    }

    // MARK: Pages captured from real Substack posts (#810, 2026-10-14)

    /// The owner's phone, 2026-10-05 to 2026-10-12: the post he shared from the Substack app (on a publication's own
    /// domain) shows a Listen button in the Substack app, but its page carries only Substack's automatic narration
    /// (`audio_items` of type `tts`, `has_voiceover` false). The owner's call (2026-10-14) is that it plays that
    /// voice, so the record is kept, marked as generated, not as the author's voiceover.
    func testAPostWithOnlySubstacksAutomaticNarrationKeepsItMarkedAsGenerated() async throws {
        let page = try Self.fixture("substack-generated-voice-only-page.html")
        let post = URL(string: "https://captured.example/p/generated-voice?r=4x1y&utm_medium=ios&triedRedirect=true")!
        XCTAssertNil(PublisherNarrationEvidence.voiceover(inPostPage: page), "it is not the author's voiceover")
        let expected = PublisherAudio(
            itemId: "item", audioURL: "https://recordings.example/tts/en-US-AlloyTurboMultilingualNeural.mp3", durationMs: nil,
            detectedFrom: "substack_post_generated_voice"
        )
        XCTAssertEqual(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: post, itemId: "item"), expected)
        let fetched = FetchedPageMemo()
        fetched.remember(Data(page.utf8), for: post)
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: post, articleURL: post.absoluteString, itemId: "item", fetched: fetched,
            fetchPage: { _ in XCTFail("the resolver's page is the answer"); throw URLError(.badURL) }
        )
        XCTAssertEqual(outcome, .found(expected))
        // Another post's page, or a page whose narration is not finished, keeps nothing.
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: URL(string: "https://captured.example/p/another")!, itemId: "item"))
        let processing = try Self.page(editingPost: { Self.editFirstAudioItem(&$0) { $0["status"] = "processing" } }, from: page)
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: processing, finalURL: post, itemId: "item"))
        for (name, edit) in [
            ("not https", { (item: inout [String: Any]) in item["audio_url"] = "http://recordings.example/a.mp3" }),
            ("no audio address", { (item: inout [String: Any]) in item["audio_url"] = NSNull() }),
            ("another post's audio", { (item: inout [String: Any]) in item["post_id"] = 99 })
        ] as [(String, (inout [String: Any]) -> Void)] {
            let edited = try Self.page(editingPost: { Self.editFirstAudioItem(&$0, edit) }, from: page)
            XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: edited, finalURL: post, itemId: "item"), name)
        }
    }

    /// A paid post read without a subscription says `has_voiceover` true but lists only a paywalled automatic
    /// narration with no audio address.
    func testAPaidPostReadWithoutASubscriptionGivesNothing() throws {
        let page = try Self.fixture("substack-paid-post-page.html")
        let post = URL(string: "https://captured.example/p/paid-post")!
        XCTAssertNil(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: post, itemId: "item"))
        XCTAssertEqual(PublisherNarrationEvidence.absence(postPage: page, finalURL: post), "generated_voice_paywalled")
    }

    /// An author's voiceover is kept, not Substack's automatic narration listed beside it, whichever comes first;
    /// the automatic narration is kept only when there is no voiceover.
    func testAPostWithBothKeepsTheAuthorsVoiceoverWhicheverIsListedFirst() throws {
        let page = try Self.fixture("substack-voiceover-and-generated-voice-page.html")
        let post = URL(string: "https://captured.example/p/voiceover-and-generated-voice?r=4x1y&utm_medium=ios")!
        let expected = PublisherAudio(
            itemId: "item", audioURL: "https://api.recordings.example/api/v1/audio/upload/11111111-2222-3333-4444-555555555555/src",
            durationMs: 1_136_378, detectedFrom: "substack_post_voiceover"
        )
        XCTAssertEqual(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: post, itemId: "item"), expected)

        let (voiceover, generated) = try Self.audioItems(of: page)
        let reversed = Self.page(withAudioItems: [generated, voiceover], from: page)
        XCTAssertEqual(PublisherNarrationEvidence.publisherAudio(postPage: reversed, finalURL: post, itemId: "item"), expected)
        let generatedOnly = Self.page(withAudioItems: [generated], from: page)
        let kept = PublisherNarrationEvidence.publisherAudio(postPage: generatedOnly, finalURL: post, itemId: "item")
        XCTAssertEqual(kept?.detectedFrom, "substack_post_generated_voice")
        XCTAssertEqual(kept?.audioURL, "https://recordings.example/tts/en-US-OnyxTurboMultilingualNeural.mp3")
    }

    /// Why a page gives no voiceover, one row per neighbouring page shape.
    func testEachWayAPageCanLackAVoiceoverHasItsOwnReason() throws {
        let post = URL(string: "https://captured.example/p/voiceover")!
        let page = try Self.page()
        func reason(_ html: String, at url: URL? = nil) -> String {
            PublisherNarrationEvidence.absence(postPage: html, finalURL: url ?? post)
        }
        func changing(_ edit: (inout [String: Any]) -> Void) throws -> String {
            try Self.page(editingPost: edit, from: page)
        }

        XCTAssertEqual(reason("<html><p>Just text.</p></html>"), "no_preloads")
        XCTAssertEqual(reason(Self.preloadsScript(root: ["publication": ["id": 1]])), "no_post")
        XCTAssertEqual(reason(try changing { $0["type"] = "podcast" }), "podcast_post")
        XCTAssertEqual(reason(try changing { $0["type"] = "thread" }), "not_a_newsletter_post")
        XCTAssertEqual(reason(try changing { $0["has_voiceover"] = false; $0["audio_items"] = NSNull() }), "no_recording")
        XCTAssertEqual(reason(try changing { $0["audio_items"] = [[String: Any]]() }), "no_recording_listed")
        XCTAssertEqual(reason(try changing { $0["audio_items"] = NSNull() }), "no_recording_listed")
        XCTAssertEqual(reason(try changing { $0["has_voiceover"] = false }), "voiceover_flag_off")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["status"] = "processing" } }), "voiceover_processing")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["status"] = "Odd status!" } }), "voiceover_Oddstatus")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["status"] = 7 } }), "voiceover_unknown")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["status"] = "" } }), "voiceover_unknown")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["status"] = String(repeating: "x", count: 500) } }), "voiceover_" + String(repeating: "x", count: 32))
        XCTAssertEqual(reason(try changing { $0.removeValue(forKey: "type") }), "not_a_newsletter_post")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["type"] = "tts"; $0["status"] = "processing" } }), "generated_voice_processing")
        XCTAssertEqual(reason(try changing { $0["canonical_url"] = NSNull() }), "voiceover_unreadable")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["type"] = "tts"; $0["audio_url"] = "http://recordings.example/a.mp3" } }), "generated_voice_unreadable")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["audio_url"] = NSNull() } }), "no_audio_url")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["audio_url"] = "http://recordings.example/a.mp3" } }), "voiceover_unreadable")
        XCTAssertEqual(reason(try changing { Self.editFirstAudioItem(&$0) { $0["post_id"] = 99 } }), "no_recording_listed")
        XCTAssertEqual(reason(page, at: URL(string: "https://captured.example/p/another-post")!), "other_post")
    }

    private static func fixture(_ name: String) throws -> String {
        String(decoding: try TestInputs.data(.contracts, "fixtures/feeds/\(name)"), as: UTF8.self)
    }

    /// The page's `window._preloads` as a dictionary.
    private static func preloads(of page: String) throws -> [String: Any] {
        let start = try XCTUnwrap(page.range(of: #"JSON.parse("#))
        let end = try XCTUnwrap(page.range(of: #");</script>"#, range: start.upperBound..<page.endIndex))
        let literal = String(page[start.upperBound..<end.lowerBound])
        let json = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static func audioItems(of page: String) throws -> ([String: Any], [String: Any]) {
        let post = try XCTUnwrap(preloads(of: page)["post"] as? [String: Any])
        let items = try XCTUnwrap(post["audio_items"] as? [[String: Any]])
        return (try XCTUnwrap(items.first { $0["type"] as? String == "voiceover" }), try XCTUnwrap(items.first { $0["type"] as? String == "tts" }))
    }

    /// `window._preloads = JSON.parse("…")` for `root`, as Substack embeds it.
    private static func preloadsScript(root: [String: Any]) -> String {
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: root)) ?? Data(), as: UTF8.self)
        let literal = String(decoding: (try? JSONEncoder().encode(json)) ?? Data(), as: UTF8.self)
        return "<script>window._preloads = JSON.parse(\(literal));</script>"
    }

    private static func page(withAudioItems items: [[String: Any]], from page: String) -> String {
        (try? Self.page(editingPost: { $0["audio_items"] = items }, from: page)) ?? ""
    }

    private static func page(editingPost edit: (inout [String: Any]) -> Void, from page: String) throws -> String {
        var root = try preloads(of: page)
        var post = try XCTUnwrap(root["post"] as? [String: Any])
        edit(&post)
        root["post"] = post
        return preloadsScript(root: root)
    }

    private static func editFirstAudioItem(_ post: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var items = post["audio_items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { return }
        edit(&items[0])
        post["audio_items"] = items
    }

    /// #810: a clipped page imports with no network, so the lookup after it must fail quietly offline and must
    /// not be taken for an answer about the post.
    func testOfflineLookupFailsWithoutAnAnswerAboutThePost() async {
        let outcome = await SharedPostVoiceoverLookup.find(
            sharedURL: substackPost, articleURL: substackPost.absoluteString, itemId: "item", fetched: nil,
            fetchPage: { _ in throw URLError(.notConnectedToInternet) }
        )
        guard case .failed = outcome else { return XCTFail("expected a failed lookup, got \(outcome)") }
    }

    func testOnlyAMissingConnectionCountsAsOffline() {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                                         .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive]
        for code in offline { XCTAssertTrue(OfflineFailure.isConnectivity(URLError(code)), "\(code)") }
        let verdicts: [URLError.Code] = [.badServerResponse, .fileDoesNotExist, .cannotDecodeContentData, .secureConnectionFailed,
                                          .dataLengthExceedsMaximum, .cancelled]
        for code in verdicts { XCTAssertFalse(OfflineFailure.isConnectivity(URLError(code)), "\(code)") }
        XCTAssertFalse(OfflineFailure.isConnectivity(CocoaError(.fileNoSuchFile)))
    }

    private let substackShare = URL(string: "https://open.substack.com/pub/captured/p/voiceover")!
    private let substackPost = URL(string: "https://captured.substack.com/p/voiceover")!

    /// The fixture, as if its post lived on a Substack host (only those are looked up).
    private static func substackPage() throws -> String {
        try page().replacingOccurrences(of: "https://captured.example/p/voiceover", with: "https://captured.substack.com/p/voiceover")
    }

    private static func page() throws -> String {
        String(decoding: try TestInputs.data(.contracts, "fixtures/feeds/substack-voiceover-page.html"), as: UTF8.self)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [URL] = []

    func append(_ url: URL) { lock.lock(); requested.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requested }
}
