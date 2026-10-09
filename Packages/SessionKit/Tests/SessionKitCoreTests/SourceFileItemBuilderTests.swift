import XCTest
@testable import SessionKit

/// #959: what Item and Listening Map a picked file becomes. The result is saved to the listener's
/// Library, so each stored field is pinned.
final class SourceFileItemBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let structure = PDFDocumentStructure(extractionEngine: .pdfKit, analysisStatus: .partial, pageCount: 2, analyzedPageCount: 0)

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/imports/\(name)")
    }

    private func prepare(_ imported: ImportedSourceText, _ name: String) throws -> PreparedObsidianImport {
        try SourceFileItemBuilder.prepare(imported, fileURL: url(name), itemId: "item-1", createdAt: now)
    }

    /// A paper with one printed heading, so its map has a chapter.
    private var paper: StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "pdfkit", version: 2, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: "A Paper\nIntro\nFirst page.\nSecond page.",
            segments: [
                .init(id: "s0", role: .title, range: .init(start: 0, length: 7), pageIndex: 0),
                .init(id: "s1", role: .heading, range: .init(start: 8, length: 5), level: 1, pageIndex: 0),
                .init(id: "s2", role: .body, range: .init(start: 14, length: 11), pageIndex: 0),
                .init(id: "s3", role: .body, range: .init(start: 26, length: 12), pageIndex: 1),
            ],
            markers: []
        )
    }

    /// Body text only: no heading to make a chapter from.
    private var flatPaper: StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "pdfkit", version: 2, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: "Only body text.",
            segments: [.init(id: "s0", role: .body, range: .init(start: 0, length: 15), pageIndex: 0)],
            markers: []
        )
    }

    // MARK: A PDF with an extraction

    func testAPDFWithAnExtractionBecomesAReadyPDFItemCarryingItsDocument() throws {
        let document = paper
        let prepared = try prepare(
            ImportedSourceText(text: document.text, documentStructure: structure, structuredDocument: document, title: "A Paper"),
            "Paper.pdf"
        )
        let item = prepared.item
        XCTAssertEqual(item.id, "item-1")
        XCTAssertEqual(item.title, "A Paper")
        XCTAssertEqual(item.mediaType, "pdf")
        XCTAssertEqual(item.text, document.text)
        XCTAssertEqual(item.externalReference, "Paper.pdf")
        XCTAssertEqual(item.externalReferenceType, "file")
        XCTAssertEqual(item.status, "ready")
        XCTAssertEqual(item.createdAt, now)
        XCTAssertEqual(item.documentStructure, structure)
        XCTAssertEqual(prepared.structuredDocument, document)
        let map = try XCTUnwrap(prepared.listeningMap)
        XCTAssertEqual(map.itemId, "item-1")
        XCTAssertEqual(map.chapters.count, 1)
    }

    func testAPDFWithoutATitleUsesTheFileNameWithoutItsExtensionAndKeepsTheFullNameAsReference() throws {
        let document = paper
        let prepared = try prepare(
            ImportedSourceText(text: document.text, documentStructure: nil, structuredDocument: document, title: nil),
            "My Paper.v2.PDF"
        )
        XCTAssertEqual(prepared.item.title, "My Paper.v2")
        XCTAssertEqual(prepared.item.externalReference, "My Paper.v2.PDF")
        XCTAssertEqual(prepared.item.mediaType, "pdf")
        XCTAssertNil(prepared.item.documentStructure)
    }

    func testAnExtractionWithNoHeadingsNeedsAListeningMapButStillKeepsItsDocument() throws {
        let document = flatPaper
        let prepared = try prepare(
            ImportedSourceText(text: document.text, documentStructure: nil, structuredDocument: document, title: "Flat"),
            "flat.pdf"
        )
        XCTAssertEqual(prepared.item.status, "needs_listening_map")
        XCTAssertNil(prepared.listeningMap)
        XCTAssertEqual(prepared.structuredDocument, document)
        XCTAssertEqual(prepared.item.mediaType, "pdf")
        XCTAssertEqual(prepared.item.text, "Only body text.")
    }

    // MARK: Text and Markdown

    func testAMarkdownFileBecomesATextItemWithSectionChapters() throws {
        let prepared = try prepare(
            ImportedSourceText(text: "# Notes\n\nSome intro text here.\n\n## Part one\n\nBody of part one.\n\n## Part two\n\nBody two.", documentStructure: nil),
            "Notes.md"
        )
        let item = prepared.item
        XCTAssertEqual(item.title, "Notes")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.externalReference, "Notes.md")
        XCTAssertEqual(item.externalReferenceType, "file")
        XCTAssertEqual(item.status, "ready")
        XCTAssertEqual(item.createdAt, now)
        XCTAssertNil(item.documentStructure)
        XCTAssertNil(prepared.structuredDocument)
        XCTAssertEqual(prepared.listeningMap?.itemId, "item-1")
        XCTAssertEqual(prepared.listeningMap?.chapters.map(\.title), ["Part one", "Part two"])
    }

    func testASourceLineInTheFrontmatterIsTheReferenceAndTheTitleLineIsTheTitle() throws {
        let prepared = try prepare(
            ImportedSourceText(text: "---\ntitle: Fm Title\nsource: https://example.com/a\n---\n# H\n\nBody text.", documentStructure: nil),
            "fm.markdown"
        )
        XCTAssertEqual(prepared.item.title, "Fm Title")
        XCTAssertEqual(prepared.item.externalReference, "https://example.com/a")
        XCTAssertEqual(prepared.item.externalReferenceType, "file")
        XCTAssertEqual(prepared.item.mediaType, "text")
    }

    func testAPlainTextFileWithNoHeadingsNeedsAListeningMap() throws {
        let prepared = try prepare(
            ImportedSourceText(text: "Just a line of plain text with no headings at all.", documentStructure: nil),
            "plain.txt"
        )
        XCTAssertEqual(prepared.item.title, "plain")
        XCTAssertEqual(prepared.item.status, "needs_listening_map")
        XCTAssertNil(prepared.listeningMap)
        XCTAssertEqual(prepared.item.mediaType, "text")
        XCTAssertEqual(prepared.item.externalReference, "plain.txt")
    }

    // MARK: The map policy

    func testAPDFsPlainTextKeepsOpeningWordsAsFrontMatterAndOtherFilesStartTheFirstSectionAtZero() throws {
        let text = "Some opening words before any heading.\n\n## Part one\n\nBody of part one.\n\n## Part two\n\nBody of part two."
        let asText = try prepare(ImportedSourceText(text: text, documentStructure: nil), "long.txt")
        XCTAssertEqual(asText.listeningMap?.chapters.map(\.title), ["Part one", "Part two"])
        XCTAssertEqual(asText.listeningMap?.chapters.first?.startChar, 0)
        XCTAssertEqual(asText.item.mediaType, "text")

        let asPDF = try prepare(ImportedSourceText(text: text, documentStructure: structure), "long.pdf")
        XCTAssertEqual(asPDF.listeningMap?.chapters.map(\.title), ["Front Matter", "Part one", "Part two"])
        XCTAssertEqual(asPDF.item.mediaType, "pdf")
        XCTAssertEqual(asPDF.item.documentStructure, structure)
        XCTAssertNil(asPDF.structuredDocument)
    }

    func testThePDFExtensionIsMatchedIgnoringCase() throws {
        let prepared = try prepare(
            ImportedSourceText(text: "# Heading\n\nPlain PDF text.\n\n## Next\n\nMore.", documentStructure: structure),
            "Scan.PDF"
        )
        XCTAssertEqual(prepared.item.mediaType, "pdf")
        XCTAssertEqual(prepared.item.status, "ready")
        XCTAssertEqual(prepared.item.externalReference, "Scan.PDF")
    }

    // MARK: Failure

    func testAFileWithNoTextThrowsSoTheImportRecordsAFailure() {
        XCTAssertThrowsError(try prepare(ImportedSourceText(text: "   \n\n  ", documentStructure: nil), "empty.md"))
        XCTAssertThrowsError(try prepare(ImportedSourceText(text: "---\ntitle: x\n---\n", documentStructure: nil), "only-frontmatter.md"))
    }

    func testTheCallerSuppliesTheItemIdAndTheClockPerFile() throws {
        let imported = ImportedSourceText(text: "# One\n\nBody.", documentStructure: nil)
        let later = now.addingTimeInterval(5)
        let first = try SourceFileItemBuilder.prepare(imported, fileURL: url("one.md"), itemId: "a", createdAt: now)
        let second = try SourceFileItemBuilder.prepare(imported, fileURL: url("one.md"), itemId: "b", createdAt: later)
        XCTAssertEqual([first.item.id, second.item.id], ["a", "b"])
        XCTAssertEqual([first.item.createdAt, second.item.createdAt], [now, later])
    }
}
