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
}
