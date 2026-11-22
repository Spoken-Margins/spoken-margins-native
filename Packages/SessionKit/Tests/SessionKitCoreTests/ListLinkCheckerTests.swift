import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 6: the list checker over a stub `URLProtocol`, the way `FollowDiscoveryGuardTests` stubs feeds. Every row of the
/// design's `network` and `long-source` device conditions is here.
final class ListLinkCheckerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let earlier = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        ListLinkStubProtocol.reset()
    }

    private func checker() -> ListLinkChecker { ListLinkChecker(session: ListLinkStubProtocol.session()) }

    private func link(
        _ url: String, accepted: [ListMember] = [], rejected: [ListMember] = [], etag: String? = nil, modified: String? = nil
    ) -> ListLink {
        ListLink(
            id: "link", listId: "list", url: url, title: "Friend", etag: etag, lastModified: modified,
            lastCheckedAt: earlier, status: .ok, statusAt: earlier,
            acceptedMembers: accepted, rejectedMembers: rejected)
    }

    private func check(_ link: ListLink) async throws -> ListLink {
        let result = await checker().check(link, now: now)
        return try XCTUnwrap(result)
    }

    // MARK: 200, 304, 301

    func testA200ReadsTheFileSavesItsValidatorsAndProposesTheDifference() async throws {
        let url = "https://one.example/list.opml"
        ListLinkStubProtocol.serve(
            url, headers: ["ETag": "\"v1\"", "Last-Modified": "Wed, 18 Nov 2026 10:00:00 GMT"],
            text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...3)))
        let result = try await check(link(url, accepted: [ListLinkFixture.member(1)]))
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.etag, "\"v1\"")
        XCTAssertEqual(result.lastModified, "Wed, 18 Nov 2026 10:00:00 GMT")
        XCTAssertEqual(result.lastCheckedAt, now)
        XCTAssertEqual(result.statusAt, now)
        XCTAssertEqual(result.pending?.added.map(\.title), ["Show 2", "Show 3"])
        XCTAssertEqual(result.acceptedMembers, [ListLinkFixture.member(1)], "a check accepts nothing by itself")
        XCTAssertEqual(ListLinkStubProtocol.headers(of: url)?["If-None-Match"], nil, "nothing to send the first time")
    }

    func testA304SendsTheValidatorsKeepsTheWaitingChangeAndMovesTheTime() async throws {
        let url = "https://two.example/list.opml"
        ListLinkStubProtocol.serve(url, status: 304, text: "")
        var waiting = link(url, etag: "\"v1\"", modified: "Wed, 18 Nov 2026 10:00:00 GMT")
        waiting.pending = ListProposal(added: [ProposedShow(member: ListLinkFixture.member(5), feedURL: ListLinkFixture.feedURL(5), title: "Five")], removed: [], checkedAt: earlier)
        let result = try await check(waiting)
        XCTAssertEqual(ListLinkStubProtocol.headers(of: url)?["If-None-Match"], "\"v1\"")
        XCTAssertEqual(ListLinkStubProtocol.headers(of: url)?["If-Modified-Since"], "Wed, 18 Nov 2026 10:00:00 GMT")
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.lastCheckedAt, now)
        XCTAssertEqual(result.pending, waiting.pending, "an unchanged file leaves the change waiting as it was")
        XCTAssertEqual(result.etag, "\"v1\"")
    }

    func testAPermanentRedirectMovesTheStoredAddressAndTheNextCheckGoesStraightThere() async throws {
        let old = "https://old.example/list.opml"
        let new = "https://new.example/list.opml"
        ListLinkStubProtocol.redirect(old, to: new, status: 301)
        ListLinkStubProtocol.serve(new, headers: ["ETag": "\"n1\""], text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1)))
        let first = try await check(link(old))
        XCTAssertEqual(first.url, new)
        XCTAssertEqual(first.status, .ok)
        XCTAssertEqual(first.pending?.added.count, 1)

        ListLinkStubProtocol.serve(new, status: 304, text: "")
        let second = try await check(first)
        XCTAssertEqual(ListLinkStubProtocol.count(of: old), 1, "the old address is not asked again")
        XCTAssertEqual(ListLinkStubProtocol.headers(of: new)?["If-None-Match"], "\"n1\"")
        XCTAssertEqual(second.url, new)
    }

    func testA308MovesTheAddressToo() async throws {
        ListLinkStubProtocol.redirect("https://a308.example/l.opml", to: "https://b308.example/l.opml", status: 308)
        ListLinkStubProtocol.serve("https://b308.example/l.opml", text: ListLinkFixture.opml())
        let result = try await check(link("https://a308.example/l.opml"))
        XCTAssertEqual(result.url, "https://b308.example/l.opml")
    }

    func testATemporaryRedirectIsFollowedButDoesNotMoveTheAddress() async throws {
        ListLinkStubProtocol.redirect("https://t.example/l.opml", to: "https://elsewhere.example/l.opml", status: 302)
        ListLinkStubProtocol.serve("https://elsewhere.example/l.opml", text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...2)))
        let result = try await check(link("https://t.example/l.opml"))
        XCTAssertEqual(result.url, "https://t.example/l.opml")
        XCTAssertEqual(result.pending?.added.count, 2, "the redirect was followed")
        // A permanent hop followed by a temporary one moves the address to the end of the permanent part only.
        ListLinkStubProtocol.redirect("https://p1.example/l.opml", to: "https://p2.example/l.opml", status: 301)
        ListLinkStubProtocol.redirect("https://p2.example/l.opml", to: "https://p3.example/l.opml", status: 302)
        ListLinkStubProtocol.serve("https://p3.example/l.opml", text: ListLinkFixture.opml())
        let mixed = try await check(link("https://p1.example/l.opml"))
        XCTAssertEqual(mixed.url, "https://p2.example/l.opml")
    }

    func testARedirectOutOfHttpsOrInALoopIsUnreachable() async throws {
        ListLinkStubProtocol.redirect("https://down.example/l.opml", to: "http://down.example/l.opml")
        let downgraded = try await check(link("https://down.example/l.opml"))
        XCTAssertEqual(downgraded.status, .unreachable)
        ListLinkStubProtocol.redirect("https://loop.example/l.opml", to: "https://loop.example/l.opml")
        let looped = try await check(link("https://loop.example/l.opml"))
        XCTAssertEqual(looped.status, .unreachable)
        XCTAssertEqual(ListLinkStubProtocol.count(of: "https://loop.example/l.opml"), ListLinkTransport.maximumRedirects + 1)
    }

    // MARK: failures leave the shows as they are

    private func assertFailureKeepsEverything(
        _ result: ListLink, original: ListLink, status: ListLink.Status, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.status, status, file: file, line: line)
        XCTAssertEqual(result.statusAt, now, file: file, line: line)
        XCTAssertEqual(result.lastCheckedAt, original.lastCheckedAt, "a failed check is not a read", file: file, line: line)
        XCTAssertEqual(result.pending, original.pending, "no partial proposal", file: file, line: line)
        XCTAssertEqual(result.acceptedMembers, original.acceptedMembers, file: file, line: line)
        XCTAssertEqual(result.rejectedMembers, original.rejectedMembers, file: file, line: line)
        XCTAssertEqual(result.etag, original.etag, file: file, line: line)
        XCTAssertEqual(result.url, original.url, file: file, line: line)
    }

    func testEachFailureShowsItsStatusAndChangesNothingElse() async throws {
        var original = link("https://fail.example/l.opml", accepted: [ListLinkFixture.member(1)], etag: "\"v1\"")
        original.pending = ListProposal(added: [], removed: [ListLinkFixture.member(1)], checkedAt: earlier)
        let cases: [(String, ListLinkStubProtocol.Reply, ListLink.Status)] = [
            ("404", .response(status: 404, headers: [:], body: Data()), .gone),
            ("410", .response(status: 410, headers: [:], body: Data()), .gone),
            ("500", .response(status: 500, headers: [:], body: Data()), .unreachable),
            ("403", .response(status: 403, headers: [:], body: Data()), .unreachable),
            ("offline", .failure(.notConnectedToInternet), .unreachable),
            ("timeout", .failure(.timedOut), .unreachable),
            ("refused", .failure(.cannotConnectToHost), .unreachable),
            ("html", .response(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html><body><p>Hello</p></body></html>".utf8)), .notAList),
            ("rss", .response(status: 200, headers: [:], body: Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>x</title></channel></rss>".utf8)), .notAList),
            ("cut off", .response(status: 200, headers: [:], body: Data("<opml version=\"2.0\"><body><outline text=\"a\"".utf8)), .notAList),
            ("empty", .response(status: 200, headers: [:], body: Data()), .notAList),
            ("5 MB", .response(status: 200, headers: [:], body: Data(repeating: 0x20, count: 5 * 1_024 * 1_024)), .tooBig),
        ]
        for (name, reply, status) in cases {
            ListLinkStubProtocol.serve(original.url, reply)
            let result = try await check(original)
            assertFailureKeepsEverything(result, original: original, status: status)
            XCTAssertEqual(result.status, status, name)
        }
    }

    func testAFileWithMoreOutlinesThanTheParserAllowsIsTooBig() async throws {
        let rows = (1...5_001).map { ListLinkFixture.Row(url: "https://many.example/f\($0).xml") }
        ListLinkStubProtocol.serve("https://many.example/l.opml", text: ListLinkFixture.opml(rows: rows))
        let result = try await check(link("https://many.example/l.opml"))
        XCTAssertEqual(result.status, .tooBig)
    }

    func testAListOfMoreThan500ShowsIsTooBigAndWritesNoProposal() async throws {
        ListLinkStubProtocol.serve("https://five.example/l.opml", text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...500)))
        let atLimit = try await check(link("https://five.example/l.opml"))
        XCTAssertEqual(atLimit.status, .ok)
        XCTAssertEqual(atLimit.pending?.added.count, 500)
        ListLinkStubProtocol.serve("https://five.example/l.opml", text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...501)))
        let over = try await check(link("https://five.example/l.opml"))
        XCTAssertEqual(over.status, .tooBig)
        XCTAssertNil(over.pending)
    }

    func testACancelledCheckSavesNothing() async throws {
        ListLinkStubProtocol.serve("https://cancel.example/l.opml", .failure(.cancelled))
        let result = await checker().check(link("https://cancel.example/l.opml"), now: now)
        XCTAssertNil(result)
    }

    func testAnAddressThatIsNotAURLIsNotAList() async throws {
        let result = try await check(link(""))
        XCTAssertEqual(result.status, .notAList)
    }

    // MARK: includes

    func testIncludedShowsComeInWithTheirIncludeTitleAndTheFileKeepsNoValidators() async throws {
        let root = "https://inc.example/root.opml"
        let child = "https://inc.example/child.opml"
        ListLinkStubProtocol.serve(
            root, headers: ["ETag": "\"root\""],
            text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1), includes: [(child, "Tech picks")]))
        ListLinkStubProtocol.serve(child, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(2...3)))
        let result = try await check(link(root))
        XCTAssertEqual(result.pending?.added.map(\.title), ["Show 1", "Show 2", "Show 3"])
        XCTAssertEqual(result.pending?.added.map(\.viaTitle), [nil, "Tech picks", "Tech picks"])
        XCTAssertNil(result.etag, "a 304 on the file would say nothing about the list it includes")
        XCTAssertEqual(ListLinkStubProtocol.headers(of: child)?["If-None-Match"], nil)
    }

    func testAnIncludedShowAlsoWrittenAsAViaRowIsOneShow() async throws {
        let root = "https://via.example/root.opml"
        let child = "https://via.example/child.opml"
        var rows = ListLinkFixture.rows(1...1)
        rows.append(ListLinkFixture.Row(url: ListLinkFixture.feedURL(2), title: "Show 2", via: "Tech picks"))
        ListLinkStubProtocol.serve(root, text: ListLinkFixture.opml(rows: rows, includes: [(child, "Tech picks")]))
        ListLinkStubProtocol.serve(child, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(2...2)))
        let result = try await check(link(root))
        XCTAssertEqual(result.pending?.added.map(\.title), ["Show 1", "Show 2"])
    }

    func testAnIncludeThatCannotBeReadKeepsTheAddsAndHoldsBackTheRemovals() async throws {
        let root = "https://fi.example/root.opml"
        let child = "https://fi.example/child.opml"
        ListLinkStubProtocol.serve(root, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...2), includes: [(child, "Down")]))
        for reply in [ListLinkStubProtocol.Reply.response(status: 500, headers: [:], body: Data()), .failure(.timedOut),
                      .response(status: 200, headers: [:], body: Data("<html></html>".utf8))] {
            ListLinkStubProtocol.serve(child, reply)
            // Show 9 came in through the include before and is missing now only because the include is down.
            let result = try await check(link(root, accepted: [ListLinkFixture.member(1), ListLinkFixture.member(9)]))
            XCTAssertEqual(result.status, .ok)
            XCTAssertEqual(result.pending?.added.map(\.title), ["Show 2"])
            XCTAssertEqual(result.pending?.removed, [], "show 9 is unread, not removed")
        }
    }

    func testACycleIsReadOnceAndStops() async throws {
        let a = "https://cyc.example/a.opml"
        let b = "https://cyc.example/b.opml/"   // the same address as b, with a trailing slash somewhere else in the file
        ListLinkStubProtocol.serve(a, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1), includes: [("https://cyc.example/b.opml", "B")]))
        ListLinkStubProtocol.serve("https://cyc.example/b.opml", text: ListLinkFixture.opml(rows: ListLinkFixture.rows(2...2), includes: [(a, "A again"), (b, "B again")]))
        let result = try await check(link(a))
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.pending?.added.map(\.title), ["Show 1", "Show 2"])
        XCTAssertEqual(ListLinkStubProtocol.count(of: a), 1)
        XCTAssertEqual(ListLinkStubProtocol.count(of: "https://cyc.example/b.opml"), 1)
        XCTAssertEqual(ListLinkStubProtocol.count(of: b), 0)
    }

    func testAChainFourDeepStopsAtThreeAndHoldsBackRemovals() async throws {
        // root includes L1, L1 includes L2, L2 includes L3, L3 includes L4: L4 is one level too deep.
        let urls = (0...4).map { "https://deep.example/l\($0).opml" }
        for depth in 0...4 {
            let includes = depth < 4 ? [(urls[depth + 1], "L\(depth + 1)")] : []
            ListLinkStubProtocol.serve(urls[depth], text: ListLinkFixture.opml(rows: ListLinkFixture.rows((depth + 1)...(depth + 1)), includes: includes))
        }
        let result = try await check(link(urls[0], accepted: [ListLinkFixture.member(5), ListLinkFixture.member(1)]))
        XCTAssertEqual(ListLinkStubProtocol.count(of: urls[3]), 1)
        XCTAssertEqual(ListLinkStubProtocol.count(of: urls[4]), 0, "depth four is not fetched")
        XCTAssertEqual(result.pending?.added.map(\.title), ["Show 1", "Show 2", "Show 3", "Show 4"].filter { $0 != "Show 1" })
        XCTAssertEqual(result.pending?.removed, [], "show 5 lives past the limit: unread, not removed")
        // The resolution says it left something out, for the preview's note.
        let document = try OPMLParser.parse(Data(ListLinkFixture.opml(includes: [(urls[0], "root")]).utf8))
        let resolution = try await checker().resolve(document, at: URL(string: "https://deep.example/start.opml")!)
        XCTAssertTrue(resolution.leftOut)
        XCTAssertTrue(resolution.incomplete)
    }

    func testARepeatLeavesSomethingOutButRemovalsAreStillProposed() async throws {
        let root = "https://rep.example/root.opml"
        let child = "https://rep.example/child.opml"
        ListLinkStubProtocol.serve(root, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1), includes: [(child, "C"), (child, "C twice")]))
        ListLinkStubProtocol.serve(child, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(2...2)))
        let document = try OPMLParser.parse(Data(ListLinkFixture.opml(includes: [(child, "C"), (child, "C twice")]).utf8))
        let resolution = try await checker().resolve(document, at: URL(string: root)!)
        XCTAssertTrue(resolution.leftOut)
        XCTAssertFalse(resolution.incomplete, "the repeat was read once, so nothing is unknown")
        let result = try await check(link(root, accepted: [ListLinkFixture.member(1), ListLinkFixture.member(8)]))
        XCTAssertEqual(result.pending?.removed, [ListLinkFixture.member(8)])
    }

    func testAnIncludeLimitOf25FilesIsKept() async throws {
        let root = "https://wide.example/root.opml"
        let includes = (1...30).map { ("https://wide.example/c\($0).opml", "C\($0)") }
        ListLinkStubProtocol.serve(root, text: ListLinkFixture.opml(includes: includes))
        for (index, include) in includes.enumerated() {
            ListLinkStubProtocol.serve(include.0, text: ListLinkFixture.opml(rows: ListLinkFixture.rows((index + 1)...(index + 1))))
        }
        let result = try await check(link(root))
        XCTAssertEqual(result.pending?.added.count, ListLinkChecker.maximumFiles - 1, "the root and 24 includes are 25 files")
    }

    func testAnIncludeThatPushesTheListPast500IsTooBig() async throws {
        let root = "https://huge.example/root.opml"
        let child = "https://huge.example/child.opml"
        ListLinkStubProtocol.serve(root, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...300), includes: [(child, "More")]))
        ListLinkStubProtocol.serve(child, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(301...601)))
        let result = try await check(link(root))
        XCTAssertEqual(result.status, .tooBig)
        XCTAssertNil(result.pending)
    }

    // MARK: what a check changes

    func testTheWaitingChangeIsRewrittenFromScratchAndClearedWhenNothingDiffers() async throws {
        let url = "https://redo.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...2)))
        var stored = link(url, accepted: [ListLinkFixture.member(1)])
        stored = try await check(stored)
        XCTAssertEqual(stored.pending?.added.map(\.title), ["Show 2"])
        // The sender removed show 2 again before the listener looked.
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1)))
        stored = try await check(stored)
        XCTAssertNil(stored.pending, "add then remove nets to nothing")
    }

    func testAGUIDMatchAfterAFeedAddressChangeProposesNothing() async throws {
        let url = "https://guid.example/l.opml"
        let moved = ListLinkFixture.Row(url: ListLinkFixture.feedURL(77), title: "Moved", guid: "GUID-1")
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: [moved]))
        let result = try await check(link(url, accepted: [ListLinkFixture.member(1, guid: "guid-1")]))
        XCTAssertNil(result.pending)
    }

    func testTheCheckSendsNoCookiesAndAsksForAList() async throws {
        let url = "https://anon.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml())
        _ = try await check(link(url))
        let headers = try XCTUnwrap(ListLinkStubProtocol.headers(of: url))
        XCTAssertNil(headers["Cookie"])
        XCTAssertTrue(headers["Accept"]?.contains("opml") == true)
    }
}
