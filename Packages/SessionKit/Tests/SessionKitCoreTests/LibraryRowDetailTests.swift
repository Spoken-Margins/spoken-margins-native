import SessionKit
import XCTest

/// #305 audit (Codex P2 on f7f5ef7): a long byline truncated the one-line detail text before the
/// item's length, so a listener couldn't see how long an article was. The length now has its own
/// part of the line, and only the rest gives way.
final class LibraryRowDetailTests: XCTestCase {
    func testTheLengthIsKeptApartFromTheTextThatTruncates() {
        let detail = LibraryRowDetail(
            byline: "The New York Review of Books", kind: "Article",
            length: "about 25 min", listening: "40%", status: "Opening audio unavailable · Live voice available"
        )
        XCTAssertEqual(detail.length, "about 25 min")
        XCTAssertFalse(detail.rest.contains("min"), "the truncating part never carries the length: \(detail.rest)")
        XCTAssertEqual(detail.rest, "The New York Review of Books · Article · 40% · Opening audio unavailable · Live voice available")
        XCTAssertEqual(detail.restAfterLength, " · " + detail.rest)
    }

    func testTheFullLineLeadsWithTheLength() {
        let detail = LibraryRowDetail(byline: "arxiv.org", kind: "PDF", length: "about 1 hr 5 min", listening: nil, status: "Offline")
        XCTAssertEqual(detail.fullLine, "about 1 hr 5 min · arxiv.org · PDF · Offline")
    }

    func testAPodcastWithoutALengthIsJustTheRest() {
        let detail = LibraryRowDetail(byline: "Radiolab", kind: "Podcast", length: nil, listening: "Completed", status: nil)
        XCTAssertNil(detail.length)
        XCTAssertEqual(detail.rest, "Radiolab · Podcast · Completed")
        XCTAssertEqual(detail.restAfterLength, detail.rest)
        XCTAssertEqual(detail.fullLine, detail.rest)
    }

    func testEmptyPartsAreSkipped() {
        let detail = LibraryRowDetail(byline: "", kind: "Text", length: "", listening: nil, status: "")
        XCTAssertNil(detail.length)
        XCTAssertEqual(detail.rest, "Text")
        XCTAssertEqual(detail.fullLine, "Text")
    }
}
