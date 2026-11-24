import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #5201: a PubMed search followed as papers. The fixture is a real reply: the search "crispr base editing" run on
/// pubmed.ncbi.nlm.nih.gov on 2026-11-24, its Create RSS form posted (15 items), and the link it gave fetched with an
/// iPhone Safari user agent. Nothing in it was edited by hand.
final class PubMedPaperReaderTests: XCTestCase {
    static let token = "1FomMFNkGLRzSnqdOiowkcxSL5oy1xngKlcjtPLJRMv8GfPMJ3"
    /// The link exactly as Create RSS's Copy gave it.
    static let createRSSLink = "https://pubmed.ncbi.nlm.nih.gov/rss/search/\(token)/?limit=15&utm_campaign=pubmed-2&fc=20261123210005"

    private func fixture() throws -> Data {
        try Data(contentsOf: TestInputs.url(.contracts, "fixtures/feeds/pubmed-rss/search-crispr-base-editing.xml"))
    }

    private func page() throws -> PubMedPaperPage { try PubMedPaperReader.read(fixture()) }

    private func entry(_ pmid: String) throws -> PaperEntry {
        try XCTUnwrap(page().entries.first { $0.pmid == pmid }, pmid)
    }

    // MARK: The real reply

    func testTheRealSearchReadsAsFifteenPapersNamedAfterTheSearch() throws {
        let page = try page()
        XCTAssertEqual(page.title, "crispr base editing", "the name given on Create RSS")
        XCTAssertEqual(page.entries.count, 15)
        XCTAssertEqual(page.skippedCount, 0)
        XCTAssertEqual(Set(page.entries.map(\.id)).count, 15)
        XCTAssertTrue(page.entries.allSatisfy { $0.provider == .pubmed && $0.id == "pubmed:\($0.pmid!)" })
        XCTAssertEqual(page.entries.first?.pmid, "43070506", "the feed's order, newest first")
    }

    func testOnePaperCarriesEveryField() throws {
        let paper = try entry("43070506")
        XCTAssertEqual(paper.title, "Gene Therapy for Leukocyte Adhesion Deficiency Type I: Current Advances, Clinical Translation, and Future Perspectives")
        XCTAssertEqual(paper.authors.prefix(3), ["Soltaninejad", "Khoshandam", "Karami"], "family names, as Zotero's are")
        XCTAssertEqual(paper.authors.count, 8)
        XCTAssertEqual(paper.journal, "Human gene therapy")
        XCTAssertEqual(paper.year, 2026)
        XCTAssertEqual(paper.doi, "10.1177/10430342261508676")
        XCTAssertEqual(paper.pageURL?.absoluteString, "https://doi.org/10.1177/10430342261508676")
        XCTAssertNil(paper.pdfURL, "not in PubMed Central")
        let abstract = try XCTUnwrap(paper.abstract)
        XCTAssertTrue(abstract.hasPrefix("Leukocyte adhesion deficiency (LAD) is a group of rare"), abstract)
        XCTAssertFalse(abstract.hasSuffix("..."), "the whole abstract, not the cut-down description")
        XCTAssertFalse(abstract.contains("<"), "no markup")
        XCTAssertFalse(abstract.contains("PMID"), "the identifier line is not the abstract")
        XCTAssertEqual(paper.dateJoined, ISO8601DateFormatter().date(from: "2026-11-23T11:00:00Z"), "the item's pubDate")
        XCTAssertEqual(paper.status, .abstractOnly)
        XCTAssertEqual(paper.citationLine, "Soltaninejad, Khoshandam et al. · Human gene therapy · 2026")
    }

    func testAStructuredAbstractKeepsItsSections() throws {
        let abstract = try XCTUnwrap(entry("43065054").abstract)
        XCTAssertTrue(abstract.hasPrefix("BACKGROUND: "), abstract)
        XCTAssertTrue(abstract.contains("\n\nCONCLUSIONS: flexiAsCas12a joins"), abstract)
    }

    func testAPaperInPubMedCentralGetsItsOpenAccessPDF() throws {
        let page = try page()
        let inPMC = page.entries.filter { $0.pdfURL != nil }
        XCTAssertEqual(inPMC.count, 6, "six items carry a pmc: identifier")
        let paper = try entry("43068270")
        XCTAssertEqual(paper.pdfURL?.absoluteString, "https://pmc-oa-opendata.s3.amazonaws.com/PMC13788774.1/PMC13788774.1.pdf")
        XCTAssertEqual(paper.status, .pdf)
        XCTAssertEqual(PaperEntryImportRoute.route(for: paper, existingItemId: nil), .pdf(paper.pdfURL!))
        XCTAssertEqual(PaperEntryImportRoute.afterPDFFailed(for: paper), .abstract, "a PDF outside the open-access set falls to the abstract")
    }

    func testAPaperWithNoAbstractAndNoAuthorsIsLinkOnlyAndOpensItsDOI() throws {
        let paper = try entry("43070160")
        XCTAssertNil(paper.abstract, "NO ABSTRACT")
        XCTAssertEqual(paper.authors, [], "the item names no author")
        XCTAssertEqual(paper.journal, "Nucleic acids research")
        XCTAssertEqual(paper.status, .linkOnly)
        XCTAssertEqual(PaperEntryImportRoute.route(for: paper, existingItemId: nil), .open(URL(string: "https://doi.org/10.1093/nar/gkag1308")))
        XCTAssertNil(AbstractItemBuilder.item(for: paper, itemId: "i", createdAt: Date()), "never an empty item")
    }

    func testAddOnAnAbstractPaperBuildsTheUsualAbstractItem() throws {
        let paper = try entry("43070506")
        let item = try XCTUnwrap(AbstractItemBuilder.item(for: paper, itemId: "i1", createdAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(item.sourceTitle, "Abstract · PubMed")
        XCTAssertEqual(item.externalReference, "https://doi.org/10.1177/10430342261508676")
        XCTAssertTrue(item.text?.contains("\n\nAbstract\n\nLeukocyte adhesion deficiency") == true)
    }

    func testNoAddressCarriesTheFeedsTrackingParameters() throws {
        for paper in try page().entries {
            for url in [paper.pageURL, paper.pdfURL].compactMap({ $0 }) {
                XCTAssertFalse(url.absoluteString.contains("utm_"), url.absoluteString)
                XCTAssertFalse(url.absoluteString.contains(Self.token), url.absoluteString)
            }
        }
    }

    // MARK: Neighbouring inputs

    func testFamilyNames() {
        let table: [(String, String?)] = [
            ("Hossein Soltaninejad", "Soltaninejad"),
            ("Anil K Challa", "Challa"),
            ("Yann G-J Sterckx", "Sterckx"),
            ("Magali Van den Kerkhof", "Van den Kerkhof"),
            ("Mohamed El Fadili", "El Fadili"),
            ("Ana da Silva", "da Silva"),
            ("Éva Varga", "Varga"),
            ("  Sharon   C\tCunningham ", "Cunningham"),
            ("Consortium", "Consortium"),
            ("Van Morrison", "Morrison"),
            ("John Smith Jr", "Smith"),
            ("Robert A Jones III", "Jones"),
            ("Jr Smith", "Smith"),
            ("", nil),
            ("   ", nil),
        ]
        for (raw, expected) in table { XCTAssertEqual(PubMedPaperReader.familyName(raw), expected, raw) }
    }

    func testYears() {
        XCTAssertEqual(PubMedPaperReader.year(citation: "Hum Gene Ther. 2026 Nov 23:10430342261508676. doi: 10.1177/x.", date: nil), 2026)
        XCTAssertEqual(PubMedPaperReader.year(citation: "Genome Biol. 2025 Aug 28;27(1):369.", date: "2026-11-20"), 2025, "the journal's year, not the day PubMed listed it")
        XCTAssertEqual(PubMedPaperReader.year(citation: "No year here.", date: "2026-11-20"), 2026)
        XCTAssertNil(PubMedPaperReader.year(citation: nil, date: nil))
        XCTAssertEqual(PubMedPaperReader.year(citation: "J 3. 12026 x 1999;", date: nil), 1999, "digits inside longer numbers are not a year")
    }

    func testPMCIDs() {
        XCTAssertEqual(PubMedPaperReader.normalizedPMCID("PMC13788774"), "PMC13788774")
        XCTAssertEqual(PubMedPaperReader.normalizedPMCID(" pmc123 "), "PMC123")
        XCTAssertNil(PubMedPaperReader.normalizedPMCID("PMC"))
        XCTAssertNil(PubMedPaperReader.normalizedPMCID("PMC12/../x"))
        XCTAssertNil(PubMedPaperReader.normalizedPMCID("13788774"))
    }

    func testAnItemWithNoPubMedIDOrNoTitleIsSkipped() throws {
        let rss = """
        <?xml version="1.0"?><rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>s</title>
        <item><title>No id</title><guid>other:1</guid></item>
        <item><title>  </title><dc:identifier>pmid:1</dc:identifier></item>
        <item><title>Guid only</title><guid isPermaLink="false">pubmed:42</guid></item>
        <item><title>Twice</title><dc:identifier>pmid:42</dc:identifier></item>
        </channel></rss>
        """
        let page = try PubMedPaperReader.read(Data(rss.utf8))
        XCTAssertEqual(page.entries.map(\.id), ["pubmed:42"])
        XCTAssertEqual(page.entries.first?.pageURL?.absoluteString, "https://pubmed.ncbi.nlm.nih.gov/42/", "no DOI: the PubMed page")
        XCTAssertEqual(page.skippedCount, 3)
    }

    func testAReplyThatIsNotRSSIsAnError() {
        for body in ["<!doctype html><html><title>403</title>403 Forbidden</html>", "{\"rss_feed_url\": \"x\"}", ""] {
            XCTAssertThrowsError(try PubMedPaperReader.read(Data(body.utf8)), body) {
                XCTAssertEqual($0 as? PubMedPaperReaderError, .notPubMedRSS)
            }
        }
        XCTAssertThrowsError(try PubMedPaperReader.read(Data(count: PubMedPaperReader.maximumBytes + 1)))
    }

    /// A refresh replaces the stored papers with what it read, so a reply that breaks off must not read as a shorter list.
    func testAReplyCutOffPartWayIsAnErrorNotAShorterList() throws {
        let whole = try fixture()
        let cut = whole.prefix(whole.count / 3)
        XCTAssertThrowsError(try PubMedPaperReader.read(Data(cut))) {
            XCTAssertEqual($0 as? PubMedPaperReaderError, .notPubMedRSS)
        }
    }

    func testRequestsArrivingTogetherAreSpacedApart() async {
        let pacer = PubMedRequestPacer()
        let clock = ContinuousClock()
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { await pacer.wait() } }
        }
        XCTAssertGreaterThanOrEqual(clock.now - start, PubMedRequestPacer.minimumSpacing * 2, "three callers take three slots")
    }

    // MARK: Following, end to end on the host

    final class FakePubMed: @unchecked Sendable {
        var reply: PaperFetchReply
        var requests: [URLRequest] = []
        private let lock = NSLock()
        init(_ reply: PaperFetchReply) { self.reply = reply }
        var transport: PaperTransport {
            { [self] request in lock.withLock { requests.append(request); return reply } }
        }
    }

    private func store() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: FileManager.default.temporaryDirectory.appending(path: "pubmed-\(UUID().uuidString).sqlite").path)
    }

    /// The regression the issue names: before #5201 a PubMed link went to the feed follow (`.notAPaperLink`).
    func testPastingACreateRSSLinkFollowsTheSearchAsPapers() async throws {
        let fake = FakePubMed(PaperFetchReply(status: 200, data: try fixture()))
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        let now = ISO8601DateFormatter().date(from: "2026-11-24T02:00:00Z")!
        let outcome = await following.follow(pasted: " \(Self.createRSSLink) ", apiKey: "a-zotero-key", zoteroConnected: true, now: now)
        guard case .followed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.id, "pubmed:rss:\(Self.token)")
        XCTAssertEqual(record.source, .pubMedRSS(token: Self.token, limit: 15))
        XCTAssertEqual(record.title, "crispr base editing")
        XCTAssertEqual(record.entries.count, 15)
        XCTAssertNil(record.totalCount)
        XCTAssertEqual(try store.loadPaperSources(), [record], "it reads back from the real store")

        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://pubmed.ncbi.nlm.nih.gov/rss/search/\(Self.token)/?limit=15", "the feed, without the tracking parameters")
        XCTAssertNil(request.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader), "a Zotero key never goes to NCBI")
        XCTAssertFalse(request.httpShouldHandleCookies)

        let row = PaperSourceRow(record: record)
        XCTAssertEqual(row.detail, "PubMed · 15 papers", "followed now: nothing is new yet")
        XCTAssertEqual(PaperSourceScreen.kindLine(record.source), "PubMed search")
        let rows = PaperSourceScreen.rows(record: record, index: PaperLibraryIndex(items: []), adding: [], pdfFailed: [], connectedUserID: nil)
        XCTAssertEqual(rows.filter { $0.statusTitle == "PDF" }.count, 6)
        XCTAssertEqual(rows.filter { $0.statusTitle == "Link only" }.map(\.entry.pmid), ["43070160"])
        XCTAssertEqual(rows.filter { $0.button == .add }.count, 14)
    }

    /// The feed publishes a day's papers hours after their 06:00 stamp. A paper first read after the listener opened
    /// the list counts as new even though its own date is earlier (audit on #5241).
    func testAPaperTheFeedAddsLaterCountsAsNewThoughItsDateIsEarlier() async throws {
        let whole = try fixture()
        let fake = FakePubMed(PaperFetchReply(status: 200, data: whole))
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        let iso = ISO8601DateFormatter()
        // Noon Eastern on Nov 23: after the day's 06:00 stamp, before the evening's batch.
        let followed = iso.date(from: "2026-11-23T17:00:00Z")!
        guard case .followed(var record) = await following.follow(pasted: Self.createRSSLink, apiKey: nil, zoteroConnected: false, now: followed)
        else { return XCTFail("not followed") }
        XCTAssertEqual(record.newCount, 0)
        XCTAssertTrue(record.entries.allSatisfy { $0.dateJoined == followed }, "on the follow every paper joins at the follow")
        let opened = iso.date(from: "2026-11-23T18:00:00Z")!
        record = try XCTUnwrap(try following.markOpened(id: record.id, now: opened))

        // The evening read: one more paper, stamped 06:00 Nov 23 like the rest of that day.
        var text = String(decoding: whole, as: UTF8.self)
        let firstItem = try XCTUnwrap(text.range(of: "<item>"))
        let added = """
        <item><title>A paper the feed added that evening</title><guid isPermaLink="false">pubmed:49999999</guid>        <pubDate>Mon, 23 Nov 2026 06:00:00 -0500</pubDate><dc:identifier>pmid:49999999</dc:identifier></item>
            
        """
        text.insert(contentsOf: added, at: firstItem.lowerBound)
        fake.reply = PaperFetchReply(status: 200, data: Data(text.utf8))
        let evening = iso.date(from: "2026-11-24T02:00:00Z")!
        guard case .success(let refreshed) = await following.refresh(record, apiKey: nil, now: evening) else { return XCTFail("refresh failed") }
        XCTAssertEqual(refreshed.newCount, 1)
        XCTAssertEqual(PaperSourceRow(record: refreshed).detail, "PubMed · 1 new paper")
        XCTAssertEqual(refreshed.entries.first?.pmid, "49999999", "the newly seen paper sorts first")
        XCTAssertEqual(refreshed.entries.first?.dateJoined, evening)
        XCTAssertEqual(refreshed.entries.filter { $0.dateJoined == followed }.count, 15, "papers already read keep their date")
        XCTAssertEqual(try store.loadPaperSources().first?.newCount, 1, "and so does the stored copy")
    }

    func testAPubMedListIsDueLikeAnyOther() {
        let record = PaperSourceRecord(source: .pubMedRSS(token: "t", limit: nil), link: "", title: "s", followedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(PaperSourceFollowing.due([record], connectedUserID: nil, now: Date(timeIntervalSince1970: 10), pulled: false).map(\.id), [record.id])
    }

    func testFailuresSayPubMedNotZotero() async throws {
        let cases: [(Int, String)] = [
            (404, "PubMed couldn't find that search. Make a new link with Create RSS."),
            (429, "PubMed is busy. Try again in a few minutes."),
            (500, "PubMed couldn't be reached. Try again later."),
            (403, "PubMed couldn't be reached. Try again later."),
        ]
        for (status, message) in cases {
            let fake = FakePubMed(PaperFetchReply(status: status, data: Data("<html>no</html>".utf8)))
            let store = try store()
            let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
            let outcome = await following.follow(pasted: Self.createRSSLink, apiKey: nil, zoteroConnected: false, now: Date())
            XCTAssertEqual(outcome, .rejected(message), "\(status)")
            XCTAssertEqual(try store.loadPaperSources(), [], "nothing stored")
        }
        let challenge = FakePubMed(PaperFetchReply(status: 200, data: Data("<!doctype html><title>Just a moment</title>".utf8)))
        let outcome = await PaperSourceFollowing(store: try store(), fetcher: PaperSourceFetcher(transport: challenge.transport))
            .follow(pasted: Self.createRSSLink, apiKey: nil, zoteroConnected: false, now: Date())
        XCTAssertEqual(outcome, .rejected("PubMed couldn't be reached. Try again later."), "a page that isn't RSS is never an empty list")
        XCTAssertEqual(PaperSourceScreen.emptyText(for: .pubMedRSS(token: "t", limit: nil)), "No papers in this search yet.")
        XCTAssertEqual(PaperSourceRow(record: PaperSourceRecord(source: .pubMedRSS(token: "t", limit: nil), link: "", title: "", followedAt: Date())).title, "PubMed search")
    }
}
