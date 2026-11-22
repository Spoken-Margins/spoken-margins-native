import CoreGraphics
import Foundation
import PDFKit
@testable import SessionKit
import SessionKitPDF
import SessionKitTestInputs
import XCTest

/// #4338, PR 3b: the PDFKit side of putting a Margin's comment on its sentence. `PDFSentenceLocator` has its own pure
/// tests on Linux; these run real PDFKit (Mac only) over `Fixtures/PDFPlacement`, a PDF written by `make-fixtures.py`
/// from public-domain text, one case per page:
///
/// | page | what it holds |
/// | --- | --- |
/// | 0 | sentences that start and end in the middle of lines |
/// | 1 | a word split with a hyphen at a line end |
/// | 2 | two columns; one sentence runs from the foot of the left column to the top of the right |
/// | 3, 4 | one sentence that starts at the foot of a page and ends on the next |
/// | 5 | the same sentence twice, after different words |
/// | 6 | a page turned a quarter turn with /Rotate |
/// | 7 | a scan: no text |
///
/// A row is misplaced when the highlight is on the wrong page or covers other lines than the sentence's own. The
/// fixture check comes first so that PDFKit reading a page differently from how it is drawn is named as that, not as
/// a placement failure.
final class PDFMarginPlacerTests: XCTestCase {
    // MARK: Fixtures

    private struct Manifest: Decodable {
        struct Line: Decodable {
            var text: String
            var x: Double
            var y: Double
        }

        struct Page: Decodable {
            var index: Int
            var kind: String
            var rotation: Int
            var startsAt: Int
            var lines: [Line]
        }

        struct LineHeight: Decodable {
            var ascent: Double
            var descent: Double
        }

        var documentText: String
        var pages: [Page]
        var lineHeight: LineHeight
    }

    private static let folder = TestInputs.packageURL("Tests/SessionKitTests/Fixtures/PDFPlacement")
    private let itemId = "item-1"

    /// Text the document holds for a page that has none in the file (an OCR'd scan), and for a sentence the file does
    /// not contain at all; appended after the real text.
    private let scanSentence = "The scanned page was read by a machine and the machine was sure of every word."
    private let absentSentence = "This sentence is not printed anywhere in the file."

    private func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: Self.folder.appending(path: "margin-placement.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func loadFixture() throws -> PDFDocument {
        let url = Self.folder.appending(path: "margin-placement.pdf")
        return try XCTUnwrap(PDFDocument(url: url), "PDFKit could not open \(url.lastPathComponent)")
    }

    /// The document as the app would hold it: the manifest's text, one segment per page, plus the two extra sentences.
    private func document(_ manifest: Manifest) -> StructuredDocument {
        let text = manifest.documentText + "\n\n" + scanSentence + "\n\n" + absentSentence
        let realLength = manifest.documentText.count
        var segments: [StructuredDocument.Segment] = []
        for (number, page) in manifest.pages.enumerated() {
            let end = number + 1 < manifest.pages.count ? manifest.pages[number + 1].startsAt : realLength
            // The scan has no text in the file; its segment is the extra sentence.
            if page.kind == "scan" { continue }
            segments.append(.init(id: "page-\(number)", role: .body, range: .init(start: page.startsAt, length: end - page.startsAt), pageIndex: number))
        }
        let scanStart = realLength + 2
        segments.append(.init(id: "page-7", role: .body, range: .init(start: scanStart, length: scanSentence.count), pageIndex: 7))
        let absentStart = scanStart + scanSentence.count + 2
        segments.append(.init(id: "page-1-extra", role: .body, range: .init(start: absentStart, length: absentSentence.count), pageIndex: 1))
        return StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: manifest.pages.count, textSHA256: nil),
            text: text,
            segments: segments,
            markers: []
        )
    }

    private func margin(_ id: String, at startChar: Int) -> Interjection {
        Interjection(
            id: id, itemId: itemId, sessionId: "session-1", targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: startChar, endChar: startChar + 1, anchorBefore: "", anchorAfter: ""),
            audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "transcribed",
            transcript: "Words of \(id).", cleanedTranscript: nil, displayText: nil, status: "active",
            captureKind: .audio
        )
    }

    /// The Character offset of the `occurrence`th (from 0) appearance of `needle` in `text`.
    private func offset(of needle: String, occurrence: Int = 0, in text: String) throws -> Int {
        var searchFrom = text.startIndex
        var found: Range<String.Index>?
        for _ in 0...occurrence {
            found = text.range(of: needle, range: searchFrom..<text.endIndex)
            guard let range = found else { break }
            searchFrom = range.upperBound
        }
        let range = try XCTUnwrap(found, "\(needle) (\(occurrence)) is not in the text")
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// The line of the manifest's page that `rect` sits on: a line whose band holds the rect's middle and that starts at
    /// or before the rect's left edge; of two columns at the same height, the right-hand one when the rect is in it.
    private func lineIndex(of rect: CGRect, on page: Manifest.Page, lineHeight: Manifest.LineHeight) -> Int? {
        let candidates = page.lines.indices.filter { index in
            let line = page.lines[index]
            return rect.midY >= line.y - lineHeight.descent && rect.midY <= line.y + lineHeight.ascent && rect.minX >= line.x - 3
        }
        return candidates.max { page.lines[$0].x < page.lines[$1].x }
    }

    // MARK: The fixture reads as drawn

    /// PDFKit's text for each page must be the lines the generator drew, in order. A failure here is about the
    /// fixture or how PDFKit reads it (columns above all), not about the placer.
    func testPDFKitReadsEveryPageAsDrawn() throws {
        let manifest = try loadManifest()
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.pageCount, manifest.pages.count)
        for page in manifest.pages {
            let text = fixture.page(at: page.index)?.string ?? ""
            if page.kind == "scan" {
                XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "page \(page.index) is a scan but PDFKit read text: \(text)")
                continue
            }
            let drawn = page.lines.map(\.text).joined(separator: "\n")
            XCTAssertEqual(
                PDFSentenceLocator.Normalized(text).characters,
                PDFSentenceLocator.Normalized(drawn).characters,
                "page \(page.index): PDFKit read \(text.debugDescription), drawn \(drawn.debugDescription)"
            )
        }
    }

    // MARK: Placement table

    private struct Row {
        var name: String
        /// Where the Margin starts: the `occurrence`th appearance of `anchor` in the document text.
        var anchor: String
        var occurrence = 0
        var page: Int
        /// The manifest line indexes (on `page`) the highlight covers, or nil for a page note.
        var lines: Set<Int>?
        var wholeSentence = true
        /// For a sentence wholly inside the left column: the right edge of every rectangle stays left of this x.
        var staysLeftOf: CGFloat?
    }

    private var rows: [Row] {
        [
            Row(name: "starts and ends mid-line, first sentence", anchor: "It is a truth universally", page: 0, lines: [0, 1]),
            Row(name: "starts mid-line and runs four lines", anchor: "However little known", page: 0, lines: [1, 2, 3, 4]),
            Row(name: "an abbreviation does not end the sentence", anchor: "Mr. Bennet replied", page: 0, lines: [5]),
            Row(name: "hyphenated at a line end", anchor: "The interference between", page: 1, lines: [0, 1]),
            Row(name: "first sentence on the hyphen page", anchor: "We repeated the measurement", page: 1, lines: [0]),
            Row(name: "one line of a column", anchor: "The committee met", page: 2, lines: [0], staysLeftOf: 330),
            Row(name: "two lines of a column", anchor: "It voted to build", page: 2, lines: [1, 2], staysLeftOf: 330),
            Row(name: "left column into the right", anchor: "Nobody spoke against", page: 2, lines: [2, 3, 4, 5]),
            Row(name: "wholly in the right column", anchor: "Children ran across", page: 2, lines: [6, 7]),
            Row(name: "across a page break: first page only, start of the sentence", anchor: "The river had risen", page: 3, lines: [0, 1], wholeSentence: false),
            Row(name: "after the page break", anchor: "Nobody went back", page: 4, lines: [0]),
            Row(name: "the same sentence, first time", anchor: "We went home.", page: 5, lines: [0]),
            Row(name: "the same sentence, second time", anchor: "We went home.", occurrence: 1, page: 5, lines: [1]),
            Row(name: "a page with no text layer", anchor: "The scanned page was read", page: 7, lines: nil),
            Row(name: "a sentence the file does not hold", anchor: "This sentence is not printed", page: 1, lines: nil)
        ]
    }

    func testEveryRowOfTheTableLandsOnItsSentence() throws {
        let manifest = try loadManifest()
        let fixture = try loadFixture()
        let doc = document(manifest)
        let margins = try rows.enumerated().map { number, row in
            margin("m\(number)", at: try offset(of: row.anchor, occurrence: row.occurrence, in: doc.text))
        }
        let plan = MarginCommentPlan.make(itemId: itemId, document: doc, margins: margins)
        let placements = try PDFMarginPlacer.place(plan: plan, document: fixture)
        XCTAssertEqual(placements.count, rows.count)
        let byMargin = Dictionary(uniqueKeysWithValues: placements.map { ($0.marginId, $0) })

        var misplaced: [String] = []
        for (number, row) in rows.enumerated() {
            guard let placement = byMargin["m\(number)"] else {
                misplaced.append("\(row.name): no placement")
                continue
            }
            guard let expectedLines = row.lines else {
                if case .pageNote(let page) = placement.spot, page == row.page { continue }
                misplaced.append("\(row.name): expected a note on page \(row.page), got \(placement.spot)")
                continue
            }
            guard case .highlight(let page, let rects, let whole) = placement.spot else {
                misplaced.append("\(row.name): expected a highlight, got \(placement.spot)")
                continue
            }
            let lines = Set(rects.compactMap { lineIndex(of: $0, on: manifest.pages[page], lineHeight: manifest.lineHeight) })
            if page != row.page || lines != expectedLines || whole != row.wholeSentence {
                misplaced.append("\(row.name): page \(page) lines \(lines.sorted()) whole \(whole); expected page \(row.page) lines \(expectedLines.sorted()) whole \(row.wholeSentence)")
            }
            if let limit = row.staysLeftOf, let widest = rects.map(\.maxX).max(), widest >= limit {
                misplaced.append("\(row.name): reaches x \(widest), past the column edge \(limit)")
            }
        }
        XCTAssertTrue(misplaced.isEmpty, "\(misplaced.count) of \(rows.count) rows misplaced:\n" + misplaced.joined(separator: "\n"))
    }

    // MARK: The turned page

    /// A page stored upright with /Rotate 90 reads as text and gets rectangles. Where the rectangles lie on a turned
    /// page is pinned by PR 4, which opens the written copy in Preview; here they must be finite, non-empty and inside
    /// the page in either orientation.
    func testARotatedPageIsPlacedWithRectanglesInsideIt() throws {
        let manifest = try loadManifest()
        let fixture = try loadFixture()
        let doc = document(manifest)
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: doc,
            margins: [margin("turned", at: try offset(of: "The old lighthouse stood", in: doc.text))]
        )
        let placements = try PDFMarginPlacer.place(plan: plan, document: fixture)
        let placement = try XCTUnwrap(placements.first)
        guard case .highlight(let page, let rects, let whole) = placement.spot else {
            return XCTFail("expected a highlight on the rotated page, got \(placement.spot)")
        }
        XCTAssertEqual(page, 6)
        XCTAssertTrue(whole)
        XCTAssertFalse(rects.isEmpty)
        let sheet = CGRect(x: 0, y: 0, width: 792, height: 792)
        for rect in rects {
            XCTAssertTrue(sheet.contains(rect), "\(rect) is outside the page")
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
        }
    }

    // MARK: Refusals and what is left alone

    func testALockedPDFIsRefused() throws {
        let url = Self.folder.appending(path: "locked.pdf")
        let locked = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(locked.isLocked, "the fixture should need a password")
        XCTAssertEqual(PDFMarginPlacer.refusal(for: locked), .locked)
        let manifest = try loadManifest()
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: document(manifest),
            margins: [margin("m", at: 0)]
        )
        XCTAssertThrowsError(try PDFMarginPlacer.place(plan: plan, document: locked)) { error in
            XCTAssertEqual(error as? PDFMarginPlacer.Failure, .locked)
        }
    }

    func testAnOpenPDFIsNotRefusedAndAnEmptyOneIs() throws {
        XCTAssertNil(PDFMarginPlacer.refusal(for: try loadFixture()))
        XCTAssertEqual(PDFMarginPlacer.refusal(for: PDFDocument()), .noPages)
    }

    /// Only Margins with words to send are placed, in the plan's order; a Margin still transcribing is left out.
    func testOnlyMarginsWithWordsArePlaced() throws {
        let manifest = try loadManifest()
        let doc = document(manifest)
        var pending = margin("pending", at: try offset(of: "However little", in: doc.text))
        pending.transcript = nil
        pending.transcriptionStatus = "pending"
        let plan = MarginCommentPlan.make(
            itemId: itemId, document: doc,
            margins: [margin("first", at: 0), pending, margin("last", at: try offset(of: "We repeated", in: doc.text))]
        )
        let placements = try PDFMarginPlacer.place(plan: plan, document: try loadFixture())
        XCTAssertEqual(placements.map(\.marginId), ["first", "last"])
    }

    func testPlacingDoesNotChangeTheFile() throws {
        let url = Self.folder.appending(path: "margin-placement.pdf")
        let before = try Data(contentsOf: url)
        let manifest = try loadManifest()
        let doc = document(manifest)
        let plan = MarginCommentPlan.make(itemId: itemId, document: doc, margins: [margin("m", at: 0)])
        _ = try PDFMarginPlacer.place(plan: plan, document: try loadFixture())
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // MARK: A long source

    /// `long-source`: 300 pages and 200 Margins. The bound is a ceiling for a pathology (a page's text read again for
    /// every Margin, or a search that grows with the square of the pages), not a measurement: the rule asks PDFKit
    /// for each page once.
    func testThreeHundredPagesAndTwoHundredMarginsPlaceWithinABound() throws {
        let pageCount = 300
        var sentences: [String] = []
        var pageObjects: [String] = []
        var documentText = ""
        var segments: [StructuredDocument.Segment] = []
        for page in 0..<pageCount {
            let first = "Page \(page) opens with its own sentence number \(page * 7 + 1)."
            let second = "Then it goes on, in the middle of page \(page), to a second sentence number \(page * 7 + 2)."
            sentences.append(first)
            let start = documentText.count
            documentText += (documentText.isEmpty ? "" : "\n\n") + first + " " + second
            let begin = start + (start == 0 ? 0 : 2)
            segments.append(.init(id: "page-\(page)", role: .body, range: .init(start: begin, length: first.count + 1 + second.count), pageIndex: page))
            pageObjects.append("BT /F1 12 Tf 1 0 0 1 72 720 Tm (\(first)) Tj ET\nBT /F1 12 Tf 1 0 0 1 72 704 Tm (\(second)) Tj ET")
        }
        let pdf = try XCTUnwrap(PDFDocument(data: Self.simplePDF(pageContents: pageObjects)))
        XCTAssertEqual(pdf.pageCount, pageCount)
        let doc = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: pageCount, textSHA256: nil),
            text: documentText, segments: segments, markers: []
        )
        let margins = try (0..<200).map { number in
            margin("m\(number)", at: try offset(of: sentences[number * 3 / 2], in: doc.text))
        }
        let plan = MarginCommentPlan.make(itemId: itemId, document: doc, margins: margins)
        let started = Date()
        let placements = try PDFMarginPlacer.place(plan: plan, document: pdf)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(placements.count, 200)
        XCTAssertEqual(placements.filter { if case .highlight = $0.spot { return true } else { return false } }.count, 200)
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.13 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a page's text read again for every Margin (see the comment above the test).
        XCTAssertLessThan(seconds, 60, "placing 200 Margins on 300 pages took \(seconds) s")
    }

    /// A PDF of upright Helvetica text pages, written by hand so the test needs no drawing code.
    private static func simplePDF(pageContents: [String]) -> Data {
        var objects: [String] = []
        let font = 3
        var kids: [Int] = []
        objects.append("") // catalog, filled below
        objects.append("") // page tree, filled below
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for content in pageContents {
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
            let contents = objects.count
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(contents) 0 R >>")
            kids.append(objects.count)
        }
        objects[0] = "<< /Type /Catalog /Pages 2 0 R >>"
        objects[1] = "<< /Type /Pages /Count \(kids.count) /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] >>"
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }
}
