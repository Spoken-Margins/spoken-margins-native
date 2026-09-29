import XCTest
@testable import SessionKit

/// #359: Library rows showed "Planet Money · Transcript Backed…" and raw arXiv URLs,
/// and an old and a new-reader import of one PDF differed only by an unlabelled icon.
final class LibraryRowWordingTests: XCTestCase {
    private func kind(_ mediaType: String, reference: String? = nil, referenceType: String? = nil, newReader: Bool = false) -> String {
        LibraryRowWording.kindLabel(
            mediaType: mediaType,
            sourceReference: reference,
            sourceReferenceType: referenceType,
            usesNewReader: newReader
        )
    }

    func testRowsNameTheKindInPlainWords() {
        XCTAssertEqual(kind("transcript_backed_media"), "Podcast")
        XCTAssertEqual(kind("podcast"), "Podcast")
        XCTAssertEqual(kind("pdf"), "PDF")
        XCTAssertEqual(kind("browser_owned_media"), "Article")
        XCTAssertEqual(kind("text", reference: "https://example.com/post", referenceType: "url"), "Article")
        XCTAssertEqual(kind("text", reference: "https://arxiv.org/pdf/2409.01234v2.pdf", referenceType: "url"), "PDF")
        XCTAssertEqual(kind("text", reference: "notes.md", referenceType: "file"), "Text")
        XCTAssertEqual(kind("epub"), "EPUB")
        XCTAssertEqual(kind("audiobook"), "Audiobook")
        XCTAssertEqual(kind("guided_tour"), "Guided tour")
    }

    func testANewReaderPDFSaysSoAndAnOlderImportDoesNot() {
        XCTAssertEqual(kind("pdf", newReader: true), "PDF, new reader")
        XCTAssertEqual(kind("pdf", newReader: false), "PDF")
        XCTAssertEqual(kind("text", newReader: true), "Text", "only PDFs have the new reader")
    }

    func testKindMatchesTheLibraryFilter() {
        XCTAssertEqual(LibraryRowWording.contentType(mediaType: "transcript_backed_media", sourceReference: nil, sourceReferenceType: nil), .podcast)
        XCTAssertEqual(LibraryRowWording.contentType(mediaType: "text", sourceReference: "paper.PDF", sourceReferenceType: "file"), .pdf)
        XCTAssertEqual(LibraryRowWording.contentType(mediaType: "text", sourceReference: "https://example.com", sourceReferenceType: "url"), .article)
    }

    func testAWebAddressBylineShowsTheSiteNotTheURL() {
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "https://arxiv.org/pdf/2409.01234v2", author: nil, title: "Paper"), "arxiv.org")
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "https://www.nytimes.com/2026/09/01/a.html", author: nil, title: "A"), "nytimes.com")
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "www.example.org/page", author: nil, title: "A"), "example.org")
    }

    func testAnAddressWithNoSiteFallsBackToTheAuthor() {
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "bundled://guided-onboarding.v1", author: "Ada", title: "A"), "Ada")
        XCTAssertNil(LibraryRowWording.byline(sourceTitle: "file:///private/var/paper.pdf", author: nil, title: "A"))
    }

    func testPlainBylinesAreKept() {
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "Planet Money", author: nil, title: "Episode"), "Planet Money")
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "[[Reading List]]", author: nil, title: "Note"), "Reading List")
        XCTAssertEqual(LibraryRowWording.byline(sourceTitle: "Paper", author: "Ada Lovelace", title: "Paper"), "Ada Lovelace")
        XCTAssertNil(LibraryRowWording.byline(sourceTitle: "  ", author: nil, title: "Paper"))
    }
}
