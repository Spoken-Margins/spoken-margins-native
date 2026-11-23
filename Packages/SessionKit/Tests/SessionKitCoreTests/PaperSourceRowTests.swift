import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4341: a followed reading list's row on Following, where it sorts among friends and shows, and its screen's rows.
final class PaperSourceRowTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func paper(_ key: String, joined: Double?, doi: String? = nil, abstract: String? = nil, pdf: String? = nil,
                       stored: String? = nil, reachable: Bool = false, page: String? = "https://example.org/p") -> PaperEntry {
        PaperEntry(id: "zotero:1:\(key)", provider: .zotero, title: "Paper \(key)", authors: ["Smith"], journal: "Nature", year: 2021,
                   doi: doi, abstract: abstract, pdfURL: pdf.flatMap(URL.init(string:)), storedPDFAttachmentKey: stored,
                   storedPDFReachable: reachable, pageURL: page.flatMap(URL.init(string:)), dateJoined: joined.map(date))
    }

    private func record(_ collection: String, title: String = "PHIL 330 readings", followed: Double = 0, opened: Double? = nil,
                        quiet: Bool = false, papers: [PaperEntry]) -> PaperSourceRecord {
        PaperSourceRecord(source: .zoteroGroup(groupID: 1, collectionKey: collection), link: "", title: title,
                          followedAt: date(followed), lastOpenedAt: opened.map(date), isQuiet: quiet, totalCount: nil, entries: papers)
    }

    // MARK: The row's words

    func testTheRowsWordsTable() {
        let twelve = (0..<12).map { paper("P\($0)", joined: -Double($0)) }
        XCTAssertEqual(PaperSourceRow(record: record("C1", papers: twelve)).detail, "Zotero · 12 papers")
        let fourNew = twelve + (0..<4).map { paper("N\($0)", joined: 10 + Double($0)) }
        let row = PaperSourceRow(record: record("C1", papers: fourNew))
        XCTAssertEqual(row.detail, "Zotero · 4 new papers")
        XCTAssertEqual(row.accessibilityLabel, "PHIL 330 readings, papers from Zotero, 4 new")
        XCTAssertEqual(PaperSourceRow(record: record("C1", opened: 20, papers: fourNew)).detail, "Zotero · 16 papers", "opened since")
        XCTAssertEqual(PaperSourceRow(record: record("C1", papers: [paper("N", joined: 5)])).detail, "Zotero · 1 new paper")
        XCTAssertEqual(PaperSourceRow(record: record("C1", papers: [paper("O", joined: -5)])).detail, "Zotero · 1 paper")
        XCTAssertEqual(PaperSourceRow(record: record("C1", papers: [])).detail, "Zotero · 0 papers")
        XCTAssertEqual(PaperSourceRow(record: record("C1", quiet: true, papers: fourNew)).detail, "Zotero · 16 papers", "Quiet counts nothing new")
        XCTAssertEqual(PaperSourceRow(record: record("C1", title: "", papers: [])).title, "Zotero library")
        XCTAssertEqual(PaperSourceRow(record: record("C1", papers: [paper("U", joined: nil)])).newCount, 0, "an undated paper is never new")
    }

    func testTheRowSortsByWhenAPaperJoinedNeverByPublicationYear() {
        var old = paper("OLD", joined: 50)
        old.year = 2019
        let list = record("C1", followed: 0, papers: [old, paper("X", joined: 10)])
        XCTAssertEqual(PaperSourceRow(record: list).newestJoinedAt, date(50))
        XCTAssertEqual(PaperSourceRow(record: record("C2", followed: 7, papers: [])).newestJoinedAt, date(7), "an empty list sorts by its follow")
    }

    func testVisibleAndQuietListsAreSplitAndOrderedNewestFirst() {
        let a = record("A", papers: [paper("a", joined: 10)])
        let b = record("B", papers: [paper("b", joined: 30)])
        let q = record("Q", quiet: true, papers: [paper("q", joined: 99)])
        XCTAssertEqual(PaperSourceRow.visible([a, b, q]).map(\.id), [b.id, a.id])
        XCTAssertEqual(PaperSourceRow.quiet([a, b, q]).map(\.id), [q.id])
    }

    // MARK: Following's one list (J13)

    private func show(_ id: String, at seconds: Double) -> FollowingShowRow {
        FollowingShowRow(
            id: id, title: id, newCount: 1, newestEpisodeTitle: "Episode", newestEpisodeDate: date(seconds), dateLabel: nil,
            playEntryID: nil, playItemID: nil, newestEntryID: nil, isQuiet: false, accessibilityLabel: id)
    }

    func testAPaperRowSitsBetweenAFriendAndAShowByItsDate() throws {
        let friendRows = FollowingFeed.rows(friends: [], shows: [show("newer", at: 100), show("older", at: 10)])
        let paperRow = PaperSourceRow(record: record("C", papers: [paper("p", joined: 50)]))
        let merged = FollowingFeed.rows(friendRows, splicingPapers: [paperRow])
        XCTAssertEqual(merged.map(\.id), ["show::newer", "papers::\(paperRow.id)", "show::older"])
        XCTAssertEqual(FollowingFeed.rows(friendRows, splicingPapers: []), friendRows, "no lists, no change (J13)")
        let tie = PaperSourceRow(record: record("T", papers: [paper("t", joined: 10)]))
        XCTAssertEqual(FollowingFeed.rows(friendRows, splicingPapers: [tie]).map(\.id).last, "papers::\(tie.id)", "a tie keeps the show first")
        XCTAssertEqual(merged[1].sortDate, date(50))
    }

    func testUnderAListChipPaperRowsAreHiddenLikeFriends() {
        let paperRow = PaperSourceRow(record: record("C", papers: [paper("p", joined: 50)]))
        let rows = FollowingFeed.rows([], splicingPapers: [paperRow])
        let list = FollowList(id: "l", name: "News", createdAt: date(0))
        let screen = FollowingByList.screen(selected: "l", lists: [list], feedRows: rows, shows: FollowingShowList(), subscriptions: [])
        XCTAssertEqual(screen.rows, [])
        XCTAssertEqual(FollowingByList.screen(selected: nil, lists: [list], feedRows: rows, shows: FollowingShowList(), subscriptions: []).rows, rows)
    }

    func testFollowingAListMeansFollowingSomething() {
        XCTAssertTrue(FollowingFeed.showsEmptyState(friends: [], shows: FollowingShowList(), showsLoaded: true))
        XCTAssertFalse(FollowingFeed.showsEmptyState(friends: [], shows: FollowingShowList(), showsLoaded: true, followsPapers: true))
    }

    // MARK: The paper screen

    func testEachPapersButton() throws {
        let entries = [
            paper("PDF", joined: 5, pdf: "https://example.org/a.pdf"),
            paper("ABS", joined: 4, abstract: "We studied sleep."),
            paper("LINK", joined: 3),
            paper("LIB", joined: 2, doi: "10.1000/lib"),
            paper("FAIL", joined: 1, pdf: "https://example.org/b.pdf"),
            paper("FAILABS", joined: 0, abstract: "Words.", pdf: "https://example.org/c.pdf"),
            paper("STORED", joined: -1, stored: "ATTACH01", reachable: true),
        ]
        var libraryItem = Item(id: "item-lib", title: "x", mediaType: "pdf", text: "x", externalReference: nil, status: "ready")
        libraryItem.documentStructure = PDFDocumentStructure(
            extractionEngine: .pdfKit, analysisStatus: .complete, pageCount: 1, analyzedPageCount: 1,
            bibliography: PDFBibliography(doi: "10.1000/LIB"))
        let index = PaperLibraryIndex(items: [libraryItem])
        let rows = PaperSourceScreen.rows(
            record: record("C", papers: entries), index: index, added: ["zotero:1:ADDED": "nope"], adding: ["zotero:1:ABS"],
            pdfFailed: ["zotero:1:FAIL", "zotero:1:FAILABS"], keyConnected: true)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.id.replacingOccurrences(of: "zotero:1:", with: ""), $0) })
        XCTAssertEqual(byKey["PDF"]?.button, .add)
        XCTAssertEqual(byKey["PDF"]?.statusTitle, "PDF")
        XCTAssertEqual(byKey["PDF"]?.statusSymbol, "doc.fill")
        XCTAssertEqual(byKey["ABS"]?.button, .adding)
        XCTAssertEqual(byKey["ABS"]?.buttonTitle, "Adding…")
        XCTAssertEqual(byKey["ABS"]?.statusTitle, "Abstract only")
        XCTAssertEqual(byKey["LINK"]?.button, .open(URL(string: "https://example.org/p")))
        XCTAssertEqual(byKey["LINK"]?.statusTitle, "Link only")
        XCTAssertEqual(byKey["LIB"]?.button, .inLibrary(itemId: "item-lib"), "matched by DOI in any case")
        XCTAssertEqual(byKey["FAIL"]?.button, .open(URL(string: "https://example.org/p")), "no PDF and no abstract: Open")
        XCTAssertEqual(byKey["FAILABS"]?.button, .add, "the abstract is still there to add")
        XCTAssertEqual(byKey["STORED"]?.status, .pdf)
        XCTAssertEqual(rows.map(\.id), entries.map(\.id), "the list's own order")
        XCTAssertEqual(byKey["PDF"]?.accessibilityLabel, "Paper PDF, Smith · Nature · 2021, PDF")
    }

    func testAPaperAddedFromTheScreenIsInLibraryBeforeTheIndexIsRebuilt() {
        let rows = PaperSourceScreen.rows(record: record("C", papers: [paper("A", joined: 1, abstract: "x")]), index: nil,
                                          added: ["zotero:1:A": "new-item"], adding: [], pdfFailed: [], keyConnected: false)
        XCTAssertEqual(rows.first?.button, .inLibrary(itemId: "new-item"))
    }

    func testAStoredPDFIsOutOfReachOnceTheKeyIsDisconnected() {
        let stored = paper("S", joined: 1, abstract: "Words.", stored: "ATTACH01", reachable: true)
        let rows = PaperSourceScreen.rows(record: record("C", papers: [stored]), index: nil, adding: [], pdfFailed: [], keyConnected: false)
        XCTAssertEqual(rows.first?.status, .abstractOnly)
        XCTAssertEqual(rows.first?.button, .add)
    }

    func testHeaderWords() {
        XCTAssertEqual(PaperSourceScreen.kindLine(.zoteroGroup(groupID: 1, collectionKey: "ABCD2345")), "Zotero collection")
        XCTAssertEqual(PaperSourceScreen.kindLine(.zoteroUser(userID: 1, collectionKey: nil)), "Zotero library")
        XCTAssertEqual(PaperSourceScreen.emptyText, "No papers in this collection yet.")
    }
}
