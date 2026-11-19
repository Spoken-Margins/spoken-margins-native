import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 6: what a pasted link points at.
final class ListLinkProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ListLinkStubProtocol.reset()
    }

    private func probe(_ text: String, status: Int = 200, contentType: String = "text/plain") async -> ListLinkProbe.Kind {
        let url = "https://probe.example/\(UUID().uuidString)"
        ListLinkStubProtocol.serve(url, status: status, headers: ["Content-Type": contentType], text: text)
        return await ListLinkProbe.probe(URL(string: url)!, session: ListLinkStubProtocol.session())
    }

    func testNeighbouringBodiesAreClassifiedByTheirRootElement() async {
        let opml = ListLinkFixture.opml(rows: ListLinkFixture.rows(1...2))
        let rss = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Show</title></channel></rss>"
        let atom = "<?xml version=\"1.0\" encoding=\"utf-8\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Show</title></feed>"
        let jsonFeed = "{\"version\": \"https://jsonfeed.org/version/1.1\", \"title\": \"Show\", \"items\": []}"
        let rows: [(String, String, ListLinkProbe.Kind)] = [
            ("opml", opml, .list),
            ("opml after a BOM and comment", "\u{FEFF}<!-- exported -->\n" + opml, .list),
            ("opml upper case root", "<?xml version=\"1.0\"?><OPML version=\"2.0\"><body/></OPML>", .list),
            ("opml with an xml doctype", "<?xml version=\"1.0\"?><!DOCTYPE opml [<!ENTITY a \"b\">]><opml version=\"2.0\"><body/></opml>", .list),
            ("rss", rss, .feed),
            ("atom", atom, .feed),
            ("rdf", "<?xml version=\"1.0\"?><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"></rdf:RDF>", .feed),
            ("json feed", jsonFeed, .feed),
            ("json that is not a feed", "{\"hello\": \"world\"}", .page),
            ("json array", "[1, 2, 3]", .page),
            ("html with a doctype", "<!DOCTYPE html><html><head><title>A page</title></head><body></body></html>", .page),
            ("html without one", "  <html><body>Hello</body></html>", .page),
            ("html that mentions opml", "<html><body><a href=\"list.opml\">Download my <opml> list</a></body></html>", .page),
            ("other xml", "<?xml version=\"1.0\"?><sitemap/>", .page),
            ("plain text", "just some words", .page),
            ("empty", "", .page),
            ("whitespace only", "  \n\t ", .page),
        ]
        for (name, body, expected) in rows {
            let kind = await probe(body)
            XCTAssertEqual(kind, expected, name)
        }
    }

    func testAnErrorStatusOrAFailedRequestIsUnreachable() async {
        for status in [404, 410, 500, 403] {
            let kind = await probe("<opml/>", status: status)
            XCTAssertEqual(kind, .unreachable, "\(status)")
        }
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotConnectToHost] {
            let url = "https://probe.example/fail-\(code.rawValue)"
            ListLinkStubProtocol.serve(url, .failure(code))
            let kind = await ListLinkProbe.probe(URL(string: url)!, session: ListLinkStubProtocol.session())
            XCTAssertEqual(kind, .unreachable)
        }
    }

    func testARedirectIsFollowedToTheListAndOneToHttpIsNot() async {
        ListLinkStubProtocol.redirect("https://probe.example/short", to: "https://probe.example/real.opml", status: 302)
        ListLinkStubProtocol.serve("https://probe.example/real.opml", text: ListLinkFixture.opml())
        var kind = await ListLinkProbe.probe(URL(string: "https://probe.example/short")!, session: ListLinkStubProtocol.session())
        XCTAssertEqual(kind, .list)
        ListLinkStubProtocol.redirect("https://probe.example/insecure", to: "http://probe.example/real.opml")
        kind = await ListLinkProbe.probe(URL(string: "https://probe.example/insecure")!, session: ListLinkStubProtocol.session())
        XCTAssertEqual(kind, .unreachable)
    }

    func testAListOverTheListLimitIsStillAListForThePreviewToRefuse() async {
        let big = ListLinkFixture.opml(rows: (1...5_001).map { ListLinkFixture.Row(url: "https://big.example/f\($0).xml") })
        let kind = await probe(big)
        XCTAssertEqual(kind, .list)
    }
}
