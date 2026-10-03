import Foundation
import XCTest
@testable import SessionKit

/// A paper's own DOI or arXiv id, found in its first pages, is what Zotero matches a Margin
/// note to (#206). A DOI the paper merely cites must never be taken for its own.
final class BibliographicReferenceExtractorTests: XCTestCase {
    private let firstPageWithFooterDOI = """
    Listening While Reading: A Field Study
    Ada Lovelace, Charles Babbage
    Abstract
    We study how people listen to papers (see Smith 2020).
    1 Introduction
    Listening is common.
    CHI '24, May 11–16, 2024, Honolulu, HI, USA
    © 2024 Copyright held by the owner/author(s).
    https://doi.org/10.1145/3613904.3642123.
    """

    func testFindsTheDOIInTheFirstPageFooter() throws {
        let created = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-03-01T12:00:00Z"))
        let bibliography = try XCTUnwrap(BibliographicReferenceExtractor.extract(
            pageTexts: [firstPageWithFooterDOI, "2 Method\nWe asked people."],
            metadataTitle: "  Listening While Reading:\n A Field Study ",
            metadataAuthor: "Ada Lovelace and Charles Babbage",
            metadataCreationDate: created
        ))
        XCTAssertEqual(bibliography, PDFBibliography(
            doi: "10.1145/3613904.3642123",
            authors: ["Ada Lovelace", "Charles Babbage"],
            year: 2024,
            title: "Listening While Reading: A Field Study"
        ))
    }

    func testADOIOnlyInTheReferenceListIsNotPicked() {
        let pageTwo = """
        5 Conclusion
        People listen.
        References
        [1] B. Smith. 2020. Reading aloud. CHI '20. https://doi.org/10.1145/3313831.3376000
        [2] C. Jones. 2019. Ears. doi:10.1038/s41586-019-1234-5
        """
        let pageOne = """
        A Short Paper
        Ada Lovelace
        As shown before [1], listening helps.
        [3] D. Lee. 2018. Earlier. https://doi.org/10.1000/182
        """
        XCTAssertNil(BibliographicReferenceExtractor.extract(pageTexts: [pageOne, pageTwo], metadataAuthor: "Ada Lovelace"))
    }

    func testReferencesBeyondTheSecondPageAreNeverRead() {
        XCTAssertNil(BibliographicReferenceExtractor.extract(
            pageTexts: ["Title\nBody.", "More body.", "Appendix\ndoi:10.5555/12345678"]
        ))
    }

    func testFindsAnArXivIdWithoutItsVersion() throws {
        let pageOne = """
        Attention Over Ears
        arXiv:2607.28282v3 [cs.CL] 30 Jul 2026
        Abstract
        We listen to transformers.
        """
        let bibliography = try XCTUnwrap(BibliographicReferenceExtractor.extract(pageTexts: [pageOne]))
        XCTAssertEqual(bibliography.arxivId, "2607.28282")
        XCTAssertNil(bibliography.doi)
        XCTAssertEqual(bibliography.authors, [])
        XCTAssertNil(bibliography.year)

        XCTAssertEqual(BibliographicReferenceExtractor.firstArXivId(in: "see https://arxiv.org/abs/hep-th/9901001v1."), "hep-th/9901001")
    }

    func testNoIdentifierGivesNoBibliography() {
        XCTAssertNil(BibliographicReferenceExtractor.extract(
            pageTexts: ["A Report\nBy the Committee\nWe met in 2024 and decided things."],
            metadataTitle: "A Report",
            metadataAuthor: "The Committee",
            metadataCreationDate: Date()
        ))
    }

    func testDOIPunctuationIsTrimmedButBracketsInsideTheDOIStay() {
        XCTAssertEqual(BibliographicReferenceExtractor.firstDOI(in: "(DOI: 10.1002/(SICI)1097-4571(199806)49:8<693::AID>3.0.CO;2-0)."), "10.1002/(SICI)1097-4571(199806)49:8")
        XCTAssertEqual(BibliographicReferenceExtractor.firstDOI(in: "(doi:10.1038/nature12373)."), "10.1038/nature12373")
        XCTAssertEqual(BibliographicReferenceExtractor.firstDOI(in: "DOI 10.1016/j.cell.2020.01.001;"), "10.1016/j.cell.2020.01.001")
    }

    func testMetadataAuthorsSplitOnlyWhereTheNamesAllowIt() {
        XCTAssertEqual(BibliographicReferenceExtractor.authors(fromMetadata: "A. Smith, B. Jones, and C. Lee"), ["A. Smith", "B. Jones", "C. Lee"])
        XCTAssertEqual(BibliographicReferenceExtractor.authors(fromMetadata: "Smith, Anna; Jones, Ben"), ["Smith, Anna", "Jones, Ben"])
        XCTAssertEqual(BibliographicReferenceExtractor.authors(fromMetadata: "Smith, Anna"), ["Smith, Anna"])
        XCTAssertEqual(BibliographicReferenceExtractor.authors(fromMetadata: "  "), [])
        XCTAssertEqual(BibliographicReferenceExtractor.authors(fromMetadata: nil), [])
    }

    func testPageIsTheOneOfTheSegmentHoldingTheCharacter() {
        let document = StructuredDocument(
            extraction: .init(engine: "pdfkit", version: 2, sourceSHA256: nil, pageCount: 3, textSHA256: nil),
            text: "Title\nFirst page.\n1\nSecond page.\nThird page.",
            segments: [
                .init(id: "s0", role: .title, range: .init(start: 0, length: 5), pageIndex: 0),
                .init(id: "s1", role: .body, range: .init(start: 6, length: 11), pageIndex: 0),
                .init(id: "s2", role: .pageFooter, range: .init(start: 18, length: 1), pageIndex: 0),
                // No footer on page 2, so its body ran on into page 3 as one segment.
                .init(id: "s3", role: .body, range: .init(start: 20, length: 24), pageIndex: 1),
            ],
            markers: []
        )
        XCTAssertEqual(document.pageNumber(atCharacter: 0), 1)
        XCTAssertEqual(document.pageNumber(atCharacter: 10), 1)
        XCTAssertEqual(document.pageNumber(atCharacter: 17), 1, "a gap between segments belongs to the one before")
        XCTAssertNil(document.pageNumber(atCharacter: 40), "a segment that may run past its first page gives no page")
        XCTAssertNil(document.pageNumber(atCharacter: -1))
    }

    func testTheLastSegmentOnTheLastPageHasThatPage() {
        let document = StructuredDocument(
            extraction: .init(engine: "pdfkit", version: 2, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: "One.\nTwo.",
            segments: [
                .init(id: "s0", role: .body, range: .init(start: 0, length: 4), pageIndex: 0),
                .init(id: "s1", role: .pageFooter, range: .init(start: 5, length: 4), pageIndex: 1),
            ],
            markers: []
        )
        XCTAssertEqual(document.pageNumber(atCharacter: 6), 2)
        XCTAssertNil(document.pageNumber(atCharacter: 1), "page 1's segment may run into page 2")
    }

    func testOtherReferenceHeadingsAlsoEndTheFrontMatter() {
        for heading in ["Notes and References", "REFERENCES AND NOTES", "Endnotes", "6 Bibliography", "Works Cited:"] {
            XCTAssertNil(BibliographicReferenceExtractor.extract(pageTexts: ["Title\nBody.\n\(heading)\nSmith. doi:10.1000/182"]), heading)
        }
    }
}
