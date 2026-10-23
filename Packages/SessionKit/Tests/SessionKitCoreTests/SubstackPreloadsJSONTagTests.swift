import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #2024, found on the owner's phone (build 34): a followed Zvi post with only Substack's automatic voice played
/// Supertonic. Substack's post pages moved `_preloads` from `window._preloads = JSON.parse("…")` into
/// `<script type="application/json" id="preloads-json">`, so every page read as `no_preloads` and the
/// publisher's voice was never found, for followed posts (#1616) and shared links (#810) alike.
final class SubstackPreloadsJSONTagTests: XCTestCase {
    private static let post = "https://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory"
    private static let mp3 = "https://substack-video.s3.amazonaws.com/video_upload/post/220859964/tts/eaac54dd-3501-416b-ad25-9e6f4875ec8a/en-US-OnyxTurboMultilingualNeural.mp3"

    private static func fixture(_ name: String) throws -> Data {
        try TestInputs.data(.contracts, "fixtures/feeds/\(name)")
    }

    private static func page() throws -> String {
        String(decoding: try fixture("substack-preloads-json-generated-voice-page.html"), as: UTF8.self)
    }

    override func setUp() {
        super.setUp()
        ZviURLProtocol.pageStatus = 200
    }

    /// The whole followed path on the live page and feed shapes: follow the feed, then the real
    /// `publisherAudioLookup` → `confirmedEntry` → `publisherAudio(for:)` chain.
    func testAFollowedPostOnTheNewPageShapeKeepsSubstacksAutomaticVoice() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = try Self.coordinator(repository)
        _ = try await coordinator.follow(urlString: "https://thezvi.substack.com/feed")
        let entries = try await coordinator.entries()
        let entry = try XCTUnwrap(entries.first { $0.canonicalURL == Self.post })
        XCTAssertEqual(entry.publisherPlatform, "substack")
        XCTAssertGreaterThanOrEqual(entry.bodyWordCount ?? 0, PublisherAudioDetector.minimumBodyWords)
        XCTAssertFalse(entry.hasPublisherAudio, "the feed alone doesn't say the post has Substack's voice")

        let lookup = await coordinator.publisherAudioLookup(for: entry, trigger: .listenerAction)
        XCTAssertEqual(lookup.outcome, "found:generated_voice")
        XCTAssertTrue(lookup.entry.hasPublisherAudio)
        XCTAssertEqual(PublisherAudioDetector.publisherAudio(for: lookup.entry, itemId: "item-browser-zvi"), PublisherAudio(
            itemId: "item-browser-zvi", audioURL: Self.mp3, durationMs: nil, detectedFrom: "substack_post_generated_voice"
        ))
        let cached = await coordinator.publisherAudioEntry(for: entry, trigger: .listenerAction)
        XCTAssertTrue(cached.hasPublisherAudio, "the confirmed entry was saved, so a second add finds it too")
    }

    /// Each reason the followed path can keep no voice gets its own token, so the next miss on a phone says why.
    func testTheLookupSaysWhyNoVoiceWasKept() async throws {
        let coordinator = try Self.coordinator(InMemorySessionRepository())
        func entry(_ url: String = SubstackPreloadsJSONTagTests.post, platform: String? = "substack", words: Int? = 2_413, confirmed: Bool? = nil) -> FeedEntry {
            FeedEntry(id: "e", subscriptionId: "s", canonicalURL: url, title: "Post", bodyWordCount: words,
                      publisherPlatform: platform, publisherNarrationConfirmed: confirmed)
        }
        let cases: [(String, FeedEntry, String)] = [
            ("not Substack", entry(platform: nil), "not_substack:none"),
            ("other platform", entry(platform: "ghost"), "not_substack:other"),
            ("short body", entry(words: 120), "short_body:120"),
            ("no body", entry(words: nil), "short_body:unknown"),
            ("not https", entry("http://thezvi.substack.com/p/leaked-anthropic-draft-ai-regulatory"), "invalid_url"),
            ("another post's page", entry("https://thezvi.substack.com/p/other"), "none:url_mismatch"),
            ("page without preloads", entry("https://thezvi.substack.com/p/plain"), "none:no_preloads"),
            ("already confirmed", entry(confirmed: true), "already_confirmed"),
        ]
        for (name, entry, expected) in cases {
            let outcome = await coordinator.publisherAudioLookup(for: entry, trigger: .listenerAction).outcome
            XCTAssertEqual(outcome, expected, name)
        }
        ZviURLProtocol.pageStatus = 403
        let blocked = await coordinator.publisherAudioLookup(for: entry(), trigger: .listenerAction).outcome
        XCTAssertEqual(blocked, "fetch_failed:http_403")
    }

    /// #2368: an import nobody started (Following's "Add every new item") must not read the publisher's post page.
    /// The voiceover is looked up when the listener opens or plays the item, so the page is read only then.
    func testABackgroundImportNeverReadsTheSubstackPostPage() async throws {
        let coordinator = try Self.coordinator(InMemorySessionRepository())
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: Self.post, title: "Post", bodyWordCount: 2_413, publisherPlatform: "substack")
        ZviURLProtocol.postPageRequests = 0

        let background = await coordinator.publisherAudioLookup(for: entry, trigger: .background)
        XCTAssertEqual(background.outcome, "deferred_until_opened")
        XCTAssertEqual(background.entry, entry, "the entry is left as the feed gave it")
        let backgroundEntry = await coordinator.publisherAudioEntry(for: entry, trigger: .background)
        XCTAssertEqual(backgroundEntry, entry)
        XCTAssertEqual(ZviURLProtocol.postPageRequests, 0, "no request reached the post page")

        let tapped = await coordinator.publisherAudioLookup(for: entry, trigger: .listenerAction)
        XCTAssertEqual(tapped.outcome, "found:generated_voice")
        XCTAssertEqual(ZviURLProtocol.postPageRequests, 1, "a tap reads the page once")

        let other = FeedEntry(id: "o", subscriptionId: "s", canonicalURL: "https://example.com/p/x", title: "Post", bodyWordCount: 2_413, publisherPlatform: "ghost")
        let elsewhere = await coordinator.publisherAudioLookup(for: other, trigger: .background)
        XCTAssertEqual(elsewhere.outcome, "not_substack:other", "other platforms keep their own token")
    }

    /// The feed's own text is what a background import of a Substack post reads (#2368).
    func testTheFeedBodyHandoffNeedsOnlyTheFeedText() {
        func entry(_ body: String?, confirmed: Bool? = nil) -> FeedEntry {
            FeedEntry(id: "e", subscriptionId: "s", canonicalURL: Self.post, title: "Post", fullBody: body, publisherNarrationConfirmed: confirmed)
        }
        XCTAssertEqual(PublisherAudioDetector.feedBodyHandoff(for: entry("Full text."))?.text, "Full text.")
        XCTAssertNil(PublisherAudioDetector.feedBodyHandoff(for: entry(nil)))
        XCTAssertNil(PublisherAudioDetector.feedBodyHandoff(for: entry("  \n ")))
        XCTAssertNil(PublisherAudioDetector.articleHandoff(for: entry("Full text.")), "the older rule still needs a confirmed voice")
    }

    /// Neighbouring shapes of the script tag: quoting, attribute order, case, whitespace, and lookalike ids.
    func testTheJSONScriptTagIsReadInItsNeighbouringShapes() throws {
        let html = try Self.page()
        let tag = #"<script type="application/json" id="preloads-json" nonce="fixture">"#
        XCTAssertTrue(html.contains(tag), "the fixture keeps the live tag")
        let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: Self.post, title: "Post", bodyWordCount: 2_413, publisherPlatform: "substack")
        let readable = [
            ("live shape", html),
            ("single quotes", html.replacingOccurrences(of: tag, with: #"<script type='application/json' id='preloads-json'>"#)),
            ("unquoted id", html.replacingOccurrences(of: tag, with: #"<script id=preloads-json type="application/json">"#)),
            ("id first", html.replacingOccurrences(of: tag, with: #"<script id="preloads-json" type="application/json">"#)),
            ("upper case", html.replacingOccurrences(of: tag, with: #"<SCRIPT TYPE="application/json" ID="preloads-json">"#)
                .replacingOccurrences(of: "}</script>", with: "}</SCRIPT>")),
            ("spaces and newlines", html.replacingOccurrences(of: tag, with: "<script\n  type=\"application/json\"\n  id = \"preloads-json\"\n>\n")),
            ("without the inline parse", html.replacingOccurrences(of: "window._preloads", with: "window._other")),
        ]
        for (name, page) in readable {
            XCTAssertEqual(PublisherNarrationEvidence.confirmedEntry(entry, html: page)?.audioURL, Self.mp3, name)
            XCTAssertEqual(PublisherNarrationEvidence.publisherAudio(postPage: page, finalURL: URL(string: Self.post)!, itemId: "i")?.detectedFrom,
                           PublisherAudioDetector.detectedFromGeneratedNarration, "\(name), shared link (#810)")
        }
        let unreadable = [
            ("lookalike id", html.replacingOccurrences(of: #"id="preloads-json""#, with: #"id="preloads-json-extra""#)),
            ("other id", html.replacingOccurrences(of: #"id="preloads-json""#, with: #"id="preloads""#)),
            ("empty tag", html.replacingOccurrences(of: #"\{"cspNonce".*\}</script>"#, with: "</script>", options: .regularExpression)),
            ("broken JSON", html.replacingOccurrences(of: #"{"cspNonce""#, with: #"{cspNonce"#)),
        ]
        for (name, page) in unreadable {
            XCTAssertNil(PublisherNarrationEvidence.confirmedEntry(entry, html: page), name)
            XCTAssertEqual(PublisherNarrationEvidence.absence(inPostPage: page), "no_preloads", name)
        }
        XCTAssertTrue(PublisherNarrationEvidence.declaresPreloads(Data(readable.last!.1.utf8)), "a shared link's page is read without the inline parse")
    }

    /// Reads the fixtures the stub serves before any request, so a missing input skips the test here
    /// instead of reaching the lookup as a failed fetch.
    private static func coordinator(_ repository: InMemorySessionRepository) throws -> FollowedSourceCoordinator {
        ZviURLProtocol.feed = try fixture("substack-zvi-generated-voice.rss")
        ZviURLProtocol.page = try fixture("substack-preloads-json-generated-voice-page.html")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZviURLProtocol.self]
        return FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: nil)
    }
}

/// thezvi.substack.com from the 2026-10-17 fixtures: the feed, the post page, a page without `_preloads`
/// and a page about another post.
private final class ZviURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pageStatus = 200
    nonisolated(unsafe) static var postPageRequests = 0
    nonisolated(unsafe) static var feed = Data()
    nonisolated(unsafe) static var page = Data()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "thezvi.substack.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasPrefix("/p/") { Self.postPageRequests += 1 }
        var status = 200
        let data: Data
        let type: String
        switch path {
        case "/feed":
            (data, type) = (Self.feed, "application/rss+xml")
        case "/p/leaked-anthropic-draft-ai-regulatory", "/p/other":
            status = Self.pageStatus
            (data, type) = (Self.page, "text/html")
        case "/p/plain":
            (data, type) = (Data("<html><body><p>No preloads here.</p></body></html>".utf8), "text/html")
        default:
            (status, data, type) = (404, Data(), "text/plain")
        }
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type]
        ) else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
