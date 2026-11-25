import Foundation
import XCTest
import SessionKit
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #4341 PR 3: what Add does with one paper. The real paper is from Zotero's public "Test Items Library" fixture
/// (the one PR 2 committed); the rest are built here to reach every row of the Design.
final class PaperEntryImportTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_800_000_000)

    private func realAbstractPaper() throws -> PaperEntry {
        let items = try Data(contentsOf: TestInputs.url(.contracts, "fixtures/feeds/zotero-group-collection.json"))
        let attachments = try Data(contentsOf: TestInputs.url(.contracts, "fixtures/feeds/zotero-group-attachments.json"))
        let page = try ZoteroPaperReader.read(items: items, attachments: [attachments], groupID: 2205533)
        return try XCTUnwrap(page.entries.first { $0.id == "zotero:2205533:34FJELMP" })
    }

    private func paper(
        title: String = "Sleep and memory",
        authors: [String] = ["Smith", "Jones", "Lee"],
        journal: String? = "Nature",
        year: Int? = 2021,
        doi: String? = "10.1000/xyz123",
        abstract: String? = "We studied sleep.",
        pdf: String? = nil,
        page: String? = "https://doi.org/10.1000/xyz123",
        provider: PaperSource.Provider = .zotero
    ) -> PaperEntry {
        PaperEntry(
            id: "zotero:1:ABC", provider: provider, title: title, authors: authors, journal: journal, year: year,
            doi: doi, pmid: nil, abstract: abstract, pdfURL: pdf.flatMap(URL.init(string:)), storedPDFAttachmentKey: nil,
            pageURL: page.flatMap(URL.init(string:)), dateJoined: nil
        )
    }

    private func item(
        _ id: String, reference: String? = nil, sourceURL: String? = nil, doi: String? = nil,
        deleted: Bool = false, created: TimeInterval = 0
    ) -> Item {
        var item = Item(
            id: id, title: "Other title", mediaType: doi == nil ? "text" : "pdf", text: "x", externalReference: reference,
            status: "ready", externalReferenceType: reference == nil ? nil : "url", sourceURL: sourceURL,
            createdAt: Date(timeIntervalSince1970: created),
            documentStructure: doi.map {
                PDFDocumentStructure(
                    extractionEngine: .pdfKit, analysisStatus: .complete, pageCount: 1, analyzedPageCount: 1,
                    bibliography: PDFBibliography(doi: $0)
                )
            }
        )
        if deleted { item.deletedAt = Date(timeIntervalSince1970: 5) }
        return item
    }

    // MARK: Route

    func testRouteTable() {
        let pdf = URL(string: "https://example.org/paper.pdf")!
        XCTAssertEqual(PaperEntryImportRoute.route(for: paper(pdf: pdf.absoluteString), existingItemId: nil), .pdf(pdf))
        XCTAssertEqual(PaperEntryImportRoute.route(for: paper(), existingItemId: nil), .abstract)
        XCTAssertEqual(
            PaperEntryImportRoute.route(for: paper(abstract: nil), existingItemId: nil),
            .open(URL(string: "https://doi.org/10.1000/xyz123"))
        )
        XCTAssertEqual(PaperEntryImportRoute.route(for: paper(abstract: nil, page: nil), existingItemId: nil), .open(nil))
        XCTAssertEqual(
            PaperEntryImportRoute.route(for: paper(abstract: " \n", page: nil), existingItemId: nil), .open(nil),
            "a blank abstract is no abstract, as AbstractItemBuilder reads it"
        )
        XCTAssertEqual(
            PaperEntryImportRoute.route(for: paper(pdf: pdf.absoluteString), existingItemId: "item-1"),
            .inLibrary(itemId: "item-1"), "already in the Library wins over every status: no duplicate"
        )
    }

    func testAPDFLinkThatReturnsAWebPageFallsBackToTheAbstractOrOpen() {
        let withAbstract = paper(pdf: "https://example.org/paywalled.pdf")
        XCTAssertEqual(PaperEntryImportRoute.afterPDFFailed(for: withAbstract), .abstract)
        let without = paper(abstract: nil, pdf: "https://example.org/paywalled.pdf")
        XCTAssertEqual(PaperEntryImportRoute.afterPDFFailed(for: without), .open(URL(string: "https://doi.org/10.1000/xyz123")))
    }

    func testAFailedPDFLinkTriesTheStoredPDFBeforeTheAbstract() {
        var both = paper(pdf: "https://example.org/paywalled.pdf")
        both.storedPDFAttachmentKey = "ATTACH01"
        both.storedPDFReachable = true
        let first = PaperEntryImportRoute.route(for: both, existingItemId: nil)
        XCTAssertEqual(first, .pdf(URL(string: "https://example.org/paywalled.pdf")!))
        let second = PaperEntryImportRoute.afterPDFFailed(for: both, failed: first)
        XCTAssertEqual(second, .storedPDF(attachmentKey: "ATTACH01"), "the file in the listener's library is there")
        XCTAssertEqual(PaperEntryImportRoute.afterPDFFailed(for: both, failed: second), .abstract, "never the stored PDF twice")
        both.storedPDFReachable = false
        XCTAssertEqual(PaperEntryImportRoute.afterPDFFailed(for: both, failed: first), .abstract, "out of reach without the key")
    }

    func testMessagesAreTheDesignsWords() {
        XCTAssertEqual(PaperAddMessage.added(title: "Sleep"), "Added “Sleep”.")
        XCTAssertEqual(PaperAddMessage.pdfNeedsLoginAbstractAdded, "The PDF needs a login, so the abstract was added.")
        XCTAssertEqual(PaperAddMessage.couldNotGetPDF, "Couldn't get the PDF.")
    }

    // MARK: Citation fallback

    func testThePDFsOwnCitationWinsWhenItFoundADOI() {
        let extracted = PDFBibliography(doi: "10.5555/own", authors: ["Pdfauthor"], year: 1999, title: "PDF title")
        XCTAssertEqual(PaperCitation.merged(extracted: extracted, entry: paper()), extracted)
    }

    func testTheFeedFillsTheCitationOnlyWhenTheExtractorFoundNoDOI() {
        let extracted = PDFBibliography(arxivId: "2101.00001", authors: ["Pdfauthor"], year: 1999, title: "PDF title")
        let merged = PaperCitation.merged(extracted: extracted, entry: paper())
        XCTAssertEqual(merged, PDFBibliography(
            doi: "10.1000/xyz123", arxivId: "2101.00001", authors: ["Smith", "Jones", "Lee"], year: 2021, title: "Sleep and memory"
        ), "the arXiv id the PDF printed is kept")
        XCTAssertEqual(
            PaperCitation.merged(extracted: nil, entry: paper()),
            PDFBibliography(doi: "10.1000/xyz123", authors: ["Smith", "Jones", "Lee"], year: 2021, title: "Sleep and memory")
        )
    }

    func testAFeedFieldThatIsMissingKeepsThePDFsValue() {
        let extracted = PDFBibliography(authors: ["Pdfauthor"], year: 1999, title: "PDF title")
        let merged = PaperCitation.merged(extracted: extracted, entry: paper(authors: [], year: nil, doi: nil))
        XCTAssertEqual(merged, PDFBibliography(authors: ["Pdfauthor"], year: 1999, title: "Sleep and memory"))
    }

    func testAnExtractedDOIThatIsNotADOIDoesNotWin() {
        let extracted = PDFBibliography(doi: "not a doi", title: "PDF title")
        XCTAssertEqual(PaperCitation.merged(extracted: extracted, entry: paper())?.doi, "10.1000/xyz123")
    }

    // MARK: Abstract item

    func testTheAbstractItemOfARealPaper() throws {
        let entry = try realAbstractPaper()
        let item = try XCTUnwrap(AbstractItemBuilder.item(for: entry, itemId: "item-paper-1", createdAt: created))
        XCTAssertEqual(item.id, "item-paper-1")
        XCTAssertEqual(item.title, entry.title)
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.sourceTitle, "Abstract · Zotero")
        XCTAssertEqual(item.createdAt, created)
        XCTAssertEqual(item.status, "needs_listening_map")
        let text = try XCTUnwrap(item.text)
        XCTAssertTrue(text.hasPrefix(AbstractItemBuilder.citationLine(for: entry) + "\n\nAbstract\n\n"))
        XCTAssertTrue(text.hasSuffix(try XCTUnwrap(entry.abstract)))
        XCTAssertEqual(item.externalReference, entry.pageURL?.absoluteString)
        XCTAssertEqual(item.externalReferenceType, "url")
        XCTAssertEqual(item.sourceURL, entry.pageURL?.absoluteString, "the item screen's open-the-source goes to the paper")
        XCTAssertEqual(item.publishedAt, "2000")
    }

    func testTheAbstractItemsTextAndSourceLine() throws {
        let item = try XCTUnwrap(AbstractItemBuilder.item(for: paper(provider: .pubmed), itemId: "i", createdAt: created))
        XCTAssertEqual(item.text, "Sleep and memory. Smith, Jones et al. Nature, 2021.\n\nAbstract\n\nWe studied sleep.")
        XCTAssertEqual(item.sourceTitle, "Abstract · PubMed")
        XCTAssertEqual(item.author, "Smith, Jones et al.")
        XCTAssertEqual(item.externalReference, "https://doi.org/10.1000/xyz123")
    }

    func testCitationLineTable() {
        let rows: [(PaperEntry, String)] = [
            (paper(), "Sleep and memory. Smith, Jones et al. Nature, 2021."),
            (paper(title: "Does sleep matter?"), "Does sleep matter? Smith, Jones et al. Nature, 2021."),
            (paper(title: "Sleep and memory."), "Sleep and memory. Smith, Jones et al. Nature, 2021."),
            (paper(authors: []), "Sleep and memory. Nature, 2021."),
            (paper(authors: ["Smith"]), "Sleep and memory. Smith. Nature, 2021."),
            (paper(journal: nil), "Sleep and memory. Smith, Jones et al. 2021."),
            (paper(year: nil), "Sleep and memory. Smith, Jones et al. Nature."),
            (paper(authors: [], journal: nil, year: nil), "Sleep and memory."),
            (paper(title: "Über Schlaf"), "Über Schlaf. Smith, Jones et al. Nature, 2021.")
        ]
        for (entry, expected) in rows {
            XCTAssertEqual(AbstractItemBuilder.citationLine(for: entry), expected)
        }
    }

    func testALinkOnlyPaperIsNeverAnEmptyItem() {
        XCTAssertNil(AbstractItemBuilder.item(for: paper(abstract: nil), itemId: "i", createdAt: created))
        XCTAssertNil(AbstractItemBuilder.item(for: paper(abstract: "  \n "), itemId: "i", createdAt: created))
    }

    func testAnAbstractWithNoAddressHasNoReference() throws {
        let item = try XCTUnwrap(AbstractItemBuilder.item(for: paper(page: nil), itemId: "i", createdAt: created))
        XCTAssertNil(item.externalReference)
        XCTAssertNil(item.externalReferenceType)
        XCTAssertNil(item.sourceURL)
    }

    // MARK: In Library

    func testDuplicateByTheDOIInAPDFsCitation() {
        let index = PaperLibraryIndex(items: [item("pdf-1", reference: "https://example.org/a.pdf", doi: "10.1000/XYZ123")])
        XCTAssertEqual(index.itemId(for: paper()), "pdf-1", "DOIs match whatever their case")
    }

    func testDuplicateByAnAbstractItemsDOIAddress() throws {
        let earlier = try XCTUnwrap(AbstractItemBuilder.item(for: paper(), itemId: "abstract-1", createdAt: created))
        XCTAssertEqual(PaperLibraryIndex(items: [earlier]).itemId(for: paper()), "abstract-1")
        let samePaperFromPubMed = paper(page: "https://dx.doi.org/10.1000/xyz123", provider: .pubmed)
        XCTAssertEqual(PaperLibraryIndex(items: [earlier]).itemId(for: samePaperFromPubMed), "abstract-1")
    }

    func testDuplicateByAddress() {
        let index = PaperLibraryIndex(items: [item("pdf-1", reference: "https://example.org/papers/a.pdf")])
        XCTAssertEqual(index.itemId(for: paper(doi: nil, pdf: "https://example.org/papers/a.pdf", page: nil)), "pdf-1")
        let pageIndex = PaperLibraryIndex(items: [item("article-1", reference: "https://journal.org/article/42")])
        XCTAssertEqual(pageIndex.itemId(for: paper(doi: nil, page: "https://journal.org/article/42")), "article-1")
    }

    func testAddressTable() {
        let stored = "https://journal.org/article/42?id=7"
        let index = PaperLibraryIndex(items: [item("a", reference: stored)])
        let same = [
            "https://journal.org/article/42?id=7",
            "http://journal.org/article/42?id=7",
            "https://www.journal.org/article/42?id=7",
            "https://JOURNAL.org/article/42?id=7",
            "https://journal.org/article/42/?id=7",
            "https://journal.org/article/42?id=7#abstract",
            "https://journal.org:443/article/42?id=7"
        ]
        for address in same {
            XCTAssertEqual(index.itemId(for: paper(doi: nil, page: address)), "a", address)
        }
        let different = [
            "https://journal.org/article/43?id=7",
            "https://journal.org/Article/42?id=7",
            "https://journal.org/article/42?id=8",
            "https://journal.org/article/42",
            "https://other.org/article/42?id=7",
            "https://journal.org:8443/article/42?id=7",
            "ftp://journal.org/article/42?id=7"
        ]
        for address in different {
            XCTAssertNil(index.itemId(for: paper(doi: nil, page: address)), address)
        }
        let paddedStore = PaperLibraryIndex(items: [item("padded", reference: " \(stored)\n")])
        XCTAssertEqual(paddedStore.itemId(for: paper(doi: nil, page: stored)), "padded", "a stored address with spaces around it")
    }

    func testANearMissTitleIsNotAMatch() {
        var sameTitle = item("pdf-1", reference: "https://example.org/a.pdf", doi: "10.1000/other")
        sameTitle.title = "Sleep and memory"
        XCTAssertNil(PaperLibraryIndex(items: [sameTitle]).itemId(for: paper()), "same title, different DOI")
    }

    func testRecentlyDeletedDoesNotCount() {
        let index = PaperLibraryIndex(items: [item("gone", reference: "https://example.org/a.pdf", doi: "10.1000/xyz123", deleted: true)])
        XCTAssertNil(index.itemId(for: paper(pdf: "https://example.org/a.pdf")))
    }

    func testTheOldestOfTwoCopiesWinsWhateverTheirOrder() {
        let older = item("older", doi: "10.1000/xyz123", created: 10)
        let newer = item("newer", doi: "10.1000/xyz123", created: 20)
        XCTAssertEqual(PaperLibraryIndex(items: [newer, older]).itemId(for: paper()), "older")
        XCTAssertEqual(PaperLibraryIndex(items: [older, newer]).itemId(for: paper()), "older")
    }

    func testADOIMatchComesBeforeAnAddressMatch() {
        let byAddress = item("by-address", reference: "https://example.org/a.pdf", created: 1)
        let byDOI = item("by-doi", doi: "10.1000/xyz123", created: 2)
        let index = PaperLibraryIndex(items: [byAddress, byDOI])
        XCTAssertEqual(index.itemId(for: paper(pdf: "https://example.org/a.pdf")), "by-doi")
    }

    func testAPaperWithNothingToMatchMatchesNothing() {
        let index = PaperLibraryIndex(items: [item("a", reference: "https://example.org/a.pdf"), item("b")])
        XCTAssertNil(index.itemId(for: paper(doi: nil, pdf: nil, page: nil)))
        XCTAssertNil(PaperLibraryIndex(items: []).itemId(for: paper()))
    }
}
