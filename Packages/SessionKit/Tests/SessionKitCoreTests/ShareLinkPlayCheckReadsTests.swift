import XCTest
@testable import SessionKit

final class ShareLinkPlayCheckReadsTests: XCTestCase {
    private func request(_ kind: String, _ url: String) -> ShareLinkPlayCheck.ReadRequest? {
        ShareLinkPlayCheck.ReadRequest(body: ["kind": kind, "url": url])
    }

    func testAPostPageAndAnAudioStartAreReadAsAsked() {
        let post = URL(string: "https://example.substack.com/p/the-post")!
        XCTAssertEqual(request("page", post.absoluteString), .page(post))
        let audio = URL(string: "https://cdn.example.com/ep.mp3?x=1")!
        XCTAssertEqual(request("audio-start", audio.absoluteString), .audioStart(audio))
        XCTAssertEqual(request("page", "https://blog.example.com/p/slug/"), .page(URL(string: "https://blog.example.com/p/slug/")!))
        XCTAssertEqual(request("page", "https://open.substack.com/pub/x/p/slug"), .page(URL(string: "https://open.substack.com/pub/x/p/slug")!))
    }

    /// A table of what the app refuses: not a post page, not https, an address of this phone or its network, an odd body.
    func testWhatTheAppRefusesToRead() {
        let refused: [(String, String, String)] = [
            ("page", "https://blog.example.com/about", "not a post page"),
            ("page", "https://blog.example.com/feed", "a feed"),
            ("page", "https://blog.example.com/p/", "no slug"),
            ("page", "http://blog.example.com/p/slug", "not https"),
            ("audio-start", "http://cdn.example.com/ep.mp3", "not https"),
            ("audio-start", "https://localhost/ep.mp3", "localhost"),
            ("audio-start", "https://192.168.1.5/ep.mp3", "a network address"),
            ("audio-start", "https://[::1]/ep.mp3", "an IPv6 address"),
            ("audio-start", "https://0x7f.0.0.1/ep.mp3", "a hex address"),
            ("audio-start", "https://2130706433/ep.mp3", "a decimal address"),
            ("audio-start", "https://0177.0.0.1/ep.mp3", "an octal address"),
            ("audio-start", "https://printer.local/ep.mp3", "a local name"),
            ("audio-start", "https://intranet.internal/ep.mp3", "an internal name"),
            ("audio-start", "https://cdn.example.com:8443/ep.mp3", "an unusual port"),
            ("audio-start", "https://user:pass@cdn.example.com/ep.mp3", "a sign-in in the address"),
            ("audio-start", "https://nodot/ep.mp3", "no dot in the host"),
            ("audio-start", "file:///etc/passwd", "a file"),
            ("audio-start", "", "empty"),
            ("play", "https://cdn.example.com/ep.mp3", "an unknown kind"),
        ]
        for (kind, url, why) in refused {
            XCTAssertNil(request(kind, url), why)
        }
        XCTAssertNil(request("audio-start", "https://cdn.example.com/" + String(repeating: "a", count: 2_100)), "very long")
        XCTAssertNil(ShareLinkPlayCheck.ReadRequest(body: "page"))
        XCTAssertNil(ShareLinkPlayCheck.ReadRequest(body: ["kind": "page"]))
        XCTAssertNil(ShareLinkPlayCheck.ReadRequest(body: ["kind": 1, "url": 2]))
        // An https address with the standard port is as good as one without.
        XCTAssertNotNil(request("audio-start", "https://cdn.example.com:443/ep.mp3"))
    }

    func testOnePageAndOneAudioStartForEachCheck() throws {
        let post = try XCTUnwrap(request("page", "https://blog.example.com/p/one"))
        let other = try XCTUnwrap(request("page", "https://blog.example.com/p/two"))
        let audio = try XCTUnwrap(request("audio-start", "https://cdn.example.com/ep.mp3"))
        var budget = ShareLinkPlayCheck.ReadBudget()
        XCTAssertTrue(budget.allow(post))
        XCTAssertFalse(budget.allow(post), "the same post twice")
        XCTAssertFalse(budget.allow(other), "a second post")
        XCTAssertTrue(budget.allow(audio))
        XCTAssertFalse(budget.allow(audio))
        // A new check has a new budget.
        var next = ShareLinkPlayCheck.ReadBudget()
        XCTAssertTrue(next.allow(other))
    }

    func testALinkIsKeptUnderItsHostAndPathAndNeverItsKey() throws {
        let id = String(repeating: "a", count: 32)
        let link = try XCTUnwrap(URL(string: "https://SpokenMargins.com/l/\(id)#key=secret"))
        XCTAssertEqual(ShareLinkPlayCheck.linkID(for: link), "spokenmargins.com/l/\(id)")
        XCTAssertFalse(ShareLinkPlayCheck.linkID(for: link)?.contains("secret") ?? true)
        XCTAssertEqual(ShareLinkPlayCheck.linkID(for: try XCTUnwrap(URL(string: "https://spokenmargins.com/l/\(id)?x=1"))), "spokenmargins.com/l/\(id)")
        XCTAssertNil(ShareLinkPlayCheck.linkID(for: try XCTUnwrap(URL(string: "https://spokenmargins.com/join"))))
    }

    func testDiagnosticsCarryACodeMillisecondsAndASizeBucketOnly() {
        XCTAssertEqual(ShareLinkPlayCheck.packetSizeBucket(0), "under-1mb")
        XCTAssertEqual(ShareLinkPlayCheck.packetSizeBucket((1 << 20) - 1), "under-1mb")
        XCTAssertEqual(ShareLinkPlayCheck.packetSizeBucket(1 << 20), "1-5mb")
        XCTAssertEqual(ShareLinkPlayCheck.packetSizeBucket(5 << 20), "5-20mb")
        XCTAssertEqual(ShareLinkPlayCheck.packetSizeBucket(20 << 20), "over-20mb")
        XCTAssertEqual(
            ShareLinkPlayCheck.diagnosticFields(for: .problem(.noPostVoice), milliseconds: 4_200, packetBytes: 300),
            ["outcome": "problem.no-post-voice", "ms": "4200", "packet": "under-1mb"]
        )
        XCTAssertEqual(ShareLinkPlayCheck.diagnosticFields(for: .plays, milliseconds: -5, packetBytes: 0)["ms"], "0")
        // Every outcome has a code, and none of the codes is a heading or carries a link.
        let outcomes: [ShareLinkPlayCheck.Outcome] = [
            .checking, .plays, .gone, .notChecked(.offline), .notChecked(.lowDataMode), .notChecked(.didNotFinish), .notChecked(.postVoiceNotLookedUp),
        ] + ShareLinkPlayCheck.Reason.allCases.map { .problem($0) }
        let codes = outcomes.map(ShareLinkPlayCheck.code(for:))
        XCTAssertEqual(Set(codes).count, outcomes.count, "one code for each outcome")
        for code in codes { XCTAssertFalse(code.contains("/") || code.contains(" "), code) }
    }

    // MARK: Apple's lookup and the show's feed (#4783, the owner's yes on 2026-11-23)

    private let lookup = "https://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200"
    private let feed = "https://feeds.soundcloud.com/users/soundcloud:users:1/sounds.rss"

    private func lookupAnswer(_ feedUrls: [Any?]) -> Data {
        let rows: [[String: Any]] = feedUrls.map { url in
            var row: [String: Any] = ["wrapperType": "track", "kind": "podcast"]
            if let url { row["feedUrl"] = url }
            return row
        } + [["wrapperType": "podcastEpisode", "trackId": 1, "episodeUrl": "https://cdn.example.com/a.mp3"]]
        return try! JSONSerialization.data(withJSONObject: ["resultCount": rows.count, "results": rows])
    }

    func testOnlyApplesLookupInItsOwnShapeIsReadAsALookup() {
        XCTAssertEqual(request("apple-lookup", lookup), .appleLookup(URL(string: lookup)!))
        let refused: [(String, String)] = [
            ("http://itunes.apple.com/lookup?id=1445582279&entity=podcastEpisode&limit=200", "not https"),
            ("https://itunes.apple.com.evil.example/lookup?id=1&entity=podcastEpisode&limit=200", "a lookalike host"),
            ("https://podcasts.apple.com/lookup?id=1&entity=podcastEpisode&limit=200", "another Apple host"),
            ("https://itunes.apple.com/search?id=1&entity=podcastEpisode&limit=200", "another path"),
            ("https://itunes.apple.com/lookup?id=1&entity=podcastEpisode&limit=200&callback=x", "an extra parameter"),
            ("https://itunes.apple.com/lookup?id=abc&entity=podcastEpisode&limit=200", "an id that is not a number"),
            ("https://itunes.apple.com/lookup?id=&entity=podcastEpisode&limit=200", "no id"),
            ("https://itunes.apple.com/lookup?id=12345678901234567890&entity=podcastEpisode&limit=200", "an id too long"),
            ("https://itunes.apple.com/lookup?entity=podcastEpisode&limit=200&id=1", "another order"),
            ("https://itunes.apple.com/lookup?id=1&entity=podcastEpisode&limit=200#x", "a fragment"),
            ("https://example.com/feed.rss", "a page that is not the lookup"),
        ]
        for (url, why) in refused {
            XCTAssertNil(request("apple-lookup", url), why)
        }
        // A lookup asked as a page is not a Substack post: refused as before.
        XCTAssertNil(request("page", lookup))
    }

    func testAFeedIsReadOnlyWhenApplesAnswerNamedIt() throws {
        let named = try XCTUnwrap(request("feed", feed))
        let elsewhere = try XCTUnwrap(request("feed", "https://attacker.example/feed.rss"))
        var budget = ShareLinkPlayCheck.ReadBudget()
        XCTAssertFalse(budget.allow(named), "no lookup answer yet: no feed")
        XCTAssertTrue(budget.allow(try XCTUnwrap(request("apple-lookup", lookup))))
        XCTAssertFalse(budget.allow(try XCTUnwrap(request("apple-lookup", lookup))), "one lookup")
        budget.noteLookupAnswer(lookupAnswer([feed]))
        XCTAssertFalse(budget.allow(elsewhere), "a feed Apple didn't name")
        XCTAssertTrue(budget.allow(named))
        XCTAssertFalse(budget.allow(named), "one feed read")
    }

    func testFeedsAppleNamesAreKeptAsHttpsAndInOneSpelling() throws {
        // Apple lists some feeds as http://; the page asks for them as https://. Host case and port 443 don't matter.
        var budget = ShareLinkPlayCheck.ReadBudget()
        budget.noteLookupAnswer(lookupAnswer(["http://Feeds.SoundCloud.com/users/soundcloud:users:1/sounds.rss"]))
        XCTAssertTrue(budget.allow(try XCTUnwrap(request("feed", "https://feeds.soundcloud.com:443/users/soundcloud:users:1/sounds.rss"))))

        let addresses = ShareLinkPlayCheck.ReadBudget.feedAddresses(inLookupAnswer: lookupAnswer([
            feed, "  https://a.example/f.xml  ", nil, "", "not a url", "ftp://a.example/f", "file:///etc/passwd",
            "https://localhost/f.xml", "https://192.168.1.5/f.xml", 42,
        ]))
        XCTAssertEqual(addresses.map(\.absoluteString), [feed, "https://a.example/f.xml"])
        XCTAssertEqual(ShareLinkPlayCheck.ReadBudget.feedAddresses(inLookupAnswer: Data("<html>".utf8)), [])
        XCTAssertEqual(ShareLinkPlayCheck.ReadBudget.feedAddresses(inLookupAnswer: Data("{\"results\":{}}".utf8)), [])
    }

    func testANewLookupAnswerReplacesTheFeedsAnEarlierOneNamed() throws {
        var budget = ShareLinkPlayCheck.ReadBudget()
        budget.noteLookupAnswer(lookupAnswer([feed]))
        budget.noteLookupAnswer(lookupAnswer([]))
        XCTAssertFalse(budget.allow(try XCTUnwrap(request("feed", feed))))
    }
}
