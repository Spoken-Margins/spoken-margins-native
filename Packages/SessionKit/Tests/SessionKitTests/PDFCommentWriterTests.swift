import CoreGraphics
import Foundation
import PDFKit
@testable import SessionKit
import SessionKitPDF
import SessionKitTestInputs
import XCTest

/// #4338, PR 4: Margins written into a copy of a real PDF as comments (Mac only: real PDFKit). The fixtures are the ones
/// `PDFMarginPlacerTests` reads (`Fixtures/PDFPlacement`): page 0 holds ordinary lines, page 6 is turned a quarter turn,
/// page 7 is a scan, and `locked.pdf` takes no comments.
final class PDFCommentWriterTests: XCTestCase {
    private static let folder = TestInputs.packageURL("Tests/SessionKitTests/Fixtures/PDFPlacement")
    private var source: URL { Self.folder.appending(path: "margin-placement.pdf") }
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-comment-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ id: String, _ words: String, status: MarginCommentPlan.Entry.Status = .included) -> MarginCommentPlan.Entry {
        MarginCommentPlan.Entry(
            marginId: id, sentence: nil, sentenceText: "", precedingText: "", pageIndex: nil,
            commentText: status == .included ? words : "", status: status
        )
    }

    private func annotations(_ document: PDFDocument, page: Int) throws -> [PDFAnnotation] {
        try XCTUnwrap(document.page(at: page)).annotations
    }

    private func assertEqual(_ a: CGRect, _ b: CGRect?, file: StaticString = #filePath, line: UInt = #line) {
        guard let b else { return XCTFail("no rectangle to compare", file: file, line: line) }
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: 0.5, file: file, line: line)
    }

    /// The `/Rect` of every annotation of `subtype` on a page, as the file spells it: in the page's default space, before
    /// `/Rotate`, whatever space PDFKit's own API speaks. This is the truth a reader opens the file against.
    private func rawRects(in url: URL, page index: Int, subtype: String) throws -> [CGRect] {
        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        let page = try XCTUnwrap(document.page(at: index + 1))
        guard let dictionary = page.dictionary else { return [] }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return [] }
        var rects: [CGRect] = []
        for position in 0..<CGPDFArrayGetCount(annotations) {
            var entry: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annotations, position, &entry), let entry else { continue }
            var name: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(entry, "Subtype", &name), let name, String(cString: name) == subtype else { continue }
            var rect: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(entry, "Rect", &rect), let rect, CGPDFArrayGetCount(rect) == 4 else { continue }
            var numbers: [CGPDFReal] = [0, 0, 0, 0]
            for number in 0..<4 { CGPDFArrayGetNumber(rect, number, &numbers[number]) }
            rects.append(CGRect(x: min(numbers[0], numbers[2]), y: min(numbers[1], numbers[3]),
                                width: abs(numbers[2] - numbers[0]), height: abs(numbers[3] - numbers[1])))
        }
        return rects
    }

    private func isHighlight(_ annotation: PDFAnnotation) -> Bool { (annotation.type ?? "").contains("Highlight") }
    private func isNote(_ annotation: PDFAnnotation) -> Bool { (annotation.type ?? "").contains("Text") }

    func testAHighlightAndPageNotesAreWrittenAsCommentsAndTheSourceIsUntouched() throws {
        let before = try Data(contentsOf: source)
        let output = directory.appending(path: "out.pdf")
        let lines = [CGRect(x: 72, y: 690, width: 220, height: 14), CGRect(x: 72, y: 674, width: 90, height: 14)]
        let plan = MarginCommentPlan(entries: [
            entry("m1", "Cite this."), entry("m2", "A note on the turned page."), entry("m3", "A second note there."), entry("m4", "On the scan."),
        ])
        let placements = [
            PDFMarginPlacement(marginId: "m1", spot: .highlight(page: 0, lineRects: lines, wholeSentence: true)),
            PDFMarginPlacement(marginId: "m2", spot: .pageNote(page: 6)),
            PDFMarginPlacement(marginId: "m3", spot: .pageNote(page: 6)),
            PDFMarginPlacement(marginId: "m4", spot: .pageNote(page: 7)),
        ]
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let summary = try PDFCommentWriter.write(source: source, plan: plan, placements: placements, author: "Ada", date: date, to: output)

        XCTAssertEqual(summary, .init(highlights: 1, pageNotes: 3, skipped: 0))
        XCTAssertEqual(try Data(contentsOf: source), before, "the original's bytes are the same")
        let copy = try XCTUnwrap(PDFDocument(url: output))
        let original = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertEqual(copy.pageCount, original.pageCount)
        XCTAssertTrue(try annotations(original, page: 0).isEmpty, "and the original has no comments")

        let highlights = try annotations(copy, page: 0).filter(isHighlight)
        XCTAssertEqual(highlights.count, 1)
        let highlight = try XCTUnwrap(highlights.first)
        XCTAssertEqual(highlight.contents, "Cite this.")
        XCTAssertEqual(highlight.userName, "Ada")
        assertEqual(highlight.bounds, PDFCommentGeometry.union(of: lines))
        XCTAssertEqual(highlight.quadrilateralPoints?.count, 8, "four corners for each of the two lines")

        let turned = try annotations(copy, page: 6).filter(isNote)
        XCTAssertEqual(turned.compactMap(\.contents).sorted(), ["A note on the turned page.", "A second note there."])
        let turnedPage = try XCTUnwrap(copy.page(at: 6))
        let slots = (0..<2).map {
            PDFCommentGeometry.pageNoteBounds(pageBounds: turnedPage.bounds(for: .cropBox), rotation: turnedPage.rotation, slot: $0)
        }
        XCTAssertEqual(Set(turned.map(\.bounds)), Set(slots), "the two notes sit in the page's visual top left, one below the other")
        XCTAssertEqual(try annotations(copy, page: 7).filter(isNote).first?.contents, "On the scan.")
    }

    /// What a reader sees: on the turned page the notes' `/Rect`s, read raw from the file, sit at the top left of the page
    /// as drawn, 18 points in from both edges, whichever space PDFKit's own bounds use. This is the check that settles
    /// the rotated page's space (#4338, PR 3b's open question) without reusing the code under test.
    func testNotesOnTheTurnedPageLandAtTheTopLeftOfThePageAsDrawn() throws {
        let output = directory.appending(path: "raw.pdf")
        let plan = MarginCommentPlan(entries: [entry("m1", "First."), entry("m2", "Second.")])
        let placements = [
            PDFMarginPlacement(marginId: "m1", spot: .pageNote(page: 6)),
            PDFMarginPlacement(marginId: "m2", spot: .pageNote(page: 6)),
        ]
        try PDFCommentWriter.write(source: source, plan: plan, placements: placements, author: "Ada", to: output)

        let raw = try XCTUnwrap(CGPDFDocument(source as CFURL)?.page(at: 7))
        let defaultSpace = raw.getBoxRect(.cropBox)
        let expected = (0..<2).map { PDFCommentGeometry.pageNoteBounds(pageBounds: defaultSpace, rotation: Int(raw.rotationAngle), slot: $0) }
        let written = try rawRects(in: output, page: 6, subtype: "Text")

        XCTAssertEqual(written.count, 2, "both notes are in the file as /Text annotations")
        XCTAssertNotEqual(raw.rotationAngle % 360, 0, "the fixture's page 6 is turned")
        for want in expected {
            XCTAssertTrue(written.contains { abs($0.minX - want.minX) < 0.5 && abs($0.minY - want.minY) < 0.5 }, "no note at \(want) among \(written)")
        }
    }

    /// The rotated page is where a rectangle can land in the wrong space (#4338, PR 3b's open question): a highlight put
    /// where PDFKit said the sentence is must cover that sentence's text when PDFKit is asked what is under it.
    func testAHighlightOnTheTurnedPageCoversTheTextItWasPlacedOn() throws {
        let document = try XCTUnwrap(PDFDocument(url: source))
        let pageText = try XCTUnwrap(document.page(at: 6)?.string)
        let sentence = String(pageText.prefix(25))
        let plan = MarginCommentPlan(entries: [
            MarginCommentPlan.Entry(
                marginId: "m1", sentence: 0..<25, sentenceText: sentence, precedingText: "", pageIndex: 6,
                commentText: "Here.", status: .included
            )
        ])
        let placements = try PDFMarginPlacer.place(plan: plan, document: document)
        guard case .highlight(let page, let rects, _) = try XCTUnwrap(placements.first).spot else {
            return XCTFail("the sentence is on the page, so it is a highlight: \(placements)")
        }
        XCTAssertEqual(page, 6)

        let output = directory.appending(path: "turned.pdf")
        try PDFCommentWriter.write(source: source, plan: plan, placements: placements, author: "Ada", to: output)

        let copy = try XCTUnwrap(PDFDocument(url: output))
        let written = try XCTUnwrap(annotations(copy, page: 6).first(where: isHighlight))
        assertEqual(written.bounds, PDFCommentGeometry.union(of: rects))
        let under = try XCTUnwrap(copy.page(at: 6)?.selection(for: written.bounds)?.string)
        XCTAssertTrue(under.contains(String(sentence.prefix(10))), "under the highlight PDFKit finds \(under.debugDescription)")
    }

    func testAMarginWithNoWordsOrNoPageIsSkippedNotWrittenEmpty() throws {
        let output = directory.appending(path: "skip.pdf")
        let plan = MarginCommentPlan(entries: [
            entry("pending", "", status: .transcriptPending), entry("blank", "   "), entry("far", "Beyond the file."), entry("ok", "Fine."),
        ])
        let placements = [
            PDFMarginPlacement(marginId: "pending", spot: .pageNote(page: 0)),
            PDFMarginPlacement(marginId: "blank", spot: .pageNote(page: 0)),
            PDFMarginPlacement(marginId: "far", spot: .pageNote(page: 99)),
            PDFMarginPlacement(marginId: "ok", spot: .pageNote(page: 0)),
            PDFMarginPlacement(marginId: "unknown", spot: .pageNote(page: 0)),
        ]

        let summary = try PDFCommentWriter.write(source: source, plan: plan, placements: placements, author: "Ada", to: output)

        XCTAssertEqual(summary, .init(highlights: 0, pageNotes: 1, skipped: 4))
        let copy = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(try annotations(copy, page: 0).filter(isNote).compactMap(\.contents), ["Fine."])
    }

    func testAHighlightWithNoRectangleBecomesAPageNote() throws {
        let output = directory.appending(path: "norect.pdf")
        let plan = MarginCommentPlan(entries: [entry("m1", "No box.")])
        let placements = [PDFMarginPlacement(marginId: "m1", spot: .highlight(page: 1, lineRects: [], wholeSentence: false))]

        let summary = try PDFCommentWriter.write(source: source, plan: plan, placements: placements, author: "Ada", to: output)

        XCTAssertEqual(summary, .init(highlights: 0, pageNotes: 1, skipped: 0))
        XCTAssertEqual(try annotations(XCTUnwrap(PDFDocument(url: output)), page: 1).filter(isNote).count, 1)
    }

    func testNoPlacementsStillWritesAnUntouchedCopy() throws {
        let output = directory.appending(path: "same.pdf")
        let summary = try PDFCommentWriter.write(source: source, plan: MarginCommentPlan(entries: []), placements: [], author: "Ada", to: output)

        XCTAssertEqual(summary, .init(highlights: 0, pageNotes: 0, skipped: 0))
        let copy = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(copy.pageCount, try XCTUnwrap(PDFDocument(url: source)).pageCount)
    }

    func testWritingOverTheSourceItselfIsRefusedAndNothingChanges() throws {
        let copy = directory.appending(path: "mine.pdf")
        try FileManager.default.copyItem(at: source, to: copy)
        let before = try Data(contentsOf: copy)
        let plan = MarginCommentPlan(entries: [entry("m1", "Words.")])

        XCTAssertThrowsError(try PDFCommentWriter.write(
            source: copy, plan: plan, placements: [PDFMarginPlacement(marginId: "m1", spot: .pageNote(page: 0))], author: "Ada", to: copy
        )) { XCTAssertEqual($0 as? PDFCommentWriter.Failure, .destinationIsTheSource) }
        XCTAssertEqual(try Data(contentsOf: copy), before)
    }

    func testALockedFileAndAFileThatIsNotAPDFAreRefused() throws {
        let plan = MarginCommentPlan(entries: [entry("m1", "Words.")])
        let placements = [PDFMarginPlacement(marginId: "m1", spot: .pageNote(page: 0))]
        let output = directory.appending(path: "locked-copy.pdf")

        XCTAssertThrowsError(try PDFCommentWriter.write(
            source: Self.folder.appending(path: "locked.pdf"), plan: plan, placements: placements, author: "Ada", to: output
        )) { XCTAssertEqual($0 as? PDFCommentWriter.Failure, .refused(.locked)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused export leaves no file")

        let notPDF = directory.appending(path: "not.pdf")
        try Data("plain text".utf8).write(to: notPDF)
        XCTAssertThrowsError(try PDFCommentWriter.write(
            source: notPDF, plan: plan, placements: placements, author: "Ada", to: directory.appending(path: "x.pdf")
        )) { XCTAssertEqual($0 as? PDFCommentWriter.Failure, .unreadable) }
    }
}
