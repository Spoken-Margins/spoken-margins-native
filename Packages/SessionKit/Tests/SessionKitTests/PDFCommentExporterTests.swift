import Foundation
import PDFKit
@testable import SessionKit
import SessionKitPDF
import SessionKitTestInputs
import XCTest

/// #4338, PR 5: the calls the export sheet makes, over the same real PDF `PDFMarginPlacerTests` reads (Mac only: real
/// PDFKit). `PDFCommentExportState` has its own pure tests on Linux.
final class PDFCommentExporterTests: XCTestCase {
    private static let folder = TestInputs.packageURL("Tests/SessionKitTests/Fixtures/PDFPlacement")
    private var source: URL { Self.folder.appending(path: "margin-placement.pdf") }
    private var directory: URL!

    private let firstSentence = "However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters."
    private let absentSentence = "This sentence is not printed anywhere in the file."

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-comment-exporter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(
        _ id: String, _ words: String, sentence: String, page: Int?, status: MarginCommentPlan.Entry.Status = .included
    ) -> MarginCommentPlan.Entry {
        MarginCommentPlan.Entry(
            marginId: id, sentence: nil, sentenceText: sentence, precedingText: "", pageIndex: page,
            commentText: status == .included ? words : "", status: status
        )
    }

    private func plan() -> MarginCommentPlan {
        MarginCommentPlan(entries: [
            entry("m1", "Cite this.", sentence: firstSentence, page: 0),
            entry("m2", "Where is this from?", sentence: absentSentence, page: 1),
            entry("m3", "", sentence: firstSentence, page: 0, status: .transcriptPending),
        ])
    }

    func testThePreviewSaysWhichCommentsLandOnASentenceAndWhichOnlyOnAPage() throws {
        let preview = try PDFCommentExporter.preview(source: source, plan: plan())
        XCTAssertEqual(preview.spots["m1"], .sentence(page: 0))
        XCTAssertEqual(preview.spots["m2"], .pageNote(page: 1))
        XCTAssertNil(preview.spots["m3"], "a Margin with no words is not placed")
        XCTAssertEqual(preview.placements.map(\.marginId), ["m1", "m2"])
    }

    func testThePreviewFeedsTheSheetsRows() throws {
        let preview = try PDFCommentExporter.preview(source: source, plan: plan())
        let state = PDFCommentExportState(plan: plan(), spots: preview.spots)
        // In page order: m1 and the pending m3 are on page 1 (m3 by its hint), m2's note is on page 2.
        XCTAssertEqual(state.rows.map(\.id), ["m1", "m3", "m2"])
        XCTAssertEqual(state.rows.map(\.status), [.onItsSentence, .transcriptPending, .pageNoExactSpot(page: 1)])
        XCTAssertEqual(state.includedIds, ["m1", "m2"])
    }

    func testOnlyTheMarginsTheListenerKeptAreWrittenAndTheOriginalIsUntouched() throws {
        let before = try Data(contentsOf: source)
        let preview = try PDFCommentExporter.preview(source: source, plan: plan())
        let output = directory.appending(path: PDFCommentExportFileName.make(title: "Draft: chapter 1"))

        let summary = try PDFCommentExporter.export(
            source: source, plan: plan(), placements: preview.placements, includedIds: ["m1"], author: "Ada", to: output)

        XCTAssertEqual(summary, .init(highlights: 1, pageNotes: 0, skipped: 0))
        XCTAssertEqual(try Data(contentsOf: source), before, "the original's bytes are the same")
        let copy = try XCTUnwrap(PDFDocument(url: output))
        let onFirst = try XCTUnwrap(copy.page(at: 0)).annotations
        XCTAssertEqual(onFirst.count, 1)
        XCTAssertEqual(onFirst.first?.contents, "Cite this.")
        XCTAssertEqual(onFirst.first?.userName, "Ada")
        XCTAssertEqual(try XCTUnwrap(copy.page(at: 1)).annotations.count, 0, "the Margin left out has no comment")
    }

    func testAnEmptyNameWritesNoAuthorAndEveryMarginKeptIsWritten() throws {
        let preview = try PDFCommentExporter.preview(source: source, plan: plan())
        let output = directory.appending(path: "all.pdf")
        let summary = try PDFCommentExporter.export(
            source: source, plan: plan(), placements: preview.placements, includedIds: ["m1", "m2"], author: "", to: output)
        XCTAssertEqual(summary, .init(highlights: 1, pageNotes: 1, skipped: 0))
        let copy = try XCTUnwrap(PDFDocument(url: output))
        let comments = try (0..<copy.pageCount).flatMap { try XCTUnwrap(copy.page(at: $0)).annotations }
        XCTAssertEqual(comments.count, 2)
        XCTAssertTrue(comments.allSatisfy { ($0.userName ?? "").isEmpty })
    }

    func testNothingKeptStillWritesAnUntouchedCopy() throws {
        let preview = try PDFCommentExporter.preview(source: source, plan: plan())
        let output = directory.appending(path: "none.pdf")
        let summary = try PDFCommentExporter.export(
            source: source, plan: plan(), placements: preview.placements, includedIds: [], author: "Ada", to: output)
        XCTAssertEqual(summary, .init(highlights: 0, pageNotes: 0, skipped: 0))
        let copy = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(copy.pageCount, PDFDocument(url: source)?.pageCount)
    }

    func testALockedFileAndAFileThatIsNotAPDFAreRefusedBeforeAnythingIsWritten() throws {
        let locked = Self.folder.appending(path: "locked.pdf")
        XCTAssertThrowsError(try PDFCommentExporter.preview(source: locked, plan: plan())) {
            XCTAssertEqual($0 as? PDFCommentWriter.Failure, .refused(.locked))
        }
        let notAPDF = directory.appending(path: "notes.pdf")
        try Data("not a pdf".utf8).write(to: notAPDF)
        XCTAssertThrowsError(try PDFCommentExporter.preview(source: notAPDF, plan: plan())) {
            XCTAssertEqual($0 as? PDFCommentWriter.Failure, .unreadable)
        }
    }

    func testTheCopyNeverGoesOverTheOriginal() throws {
        let kept = directory.appending(path: "original.pdf")
        try FileManager.default.copyItem(at: source, to: kept)
        let before = try Data(contentsOf: kept)
        let preview = try PDFCommentExporter.preview(source: kept, plan: plan())
        XCTAssertThrowsError(try PDFCommentExporter.export(
            source: kept, plan: plan(), placements: preview.placements, includedIds: ["m1"], author: "Ada", to: kept)
        ) { XCTAssertEqual($0 as? PDFCommentWriter.Failure, .destinationIsTheSource) }
        XCTAssertEqual(try Data(contentsOf: kept), before)
    }

    // MARK: A chosen file for a PDF with no copy on this iPhone (#4338, PR 6)

    func testTheSameFileIsAcceptedWithItsPlacements() throws {
        let pages = try XCTUnwrap(PDFDocument(url: source)).pageCount
        // m1 lands on its sentence, m2 only on a page: one of two is half, which is enough.
        guard case .accepted(let preview) = PDFCommentExporter.check(chosen: source, plan: plan(), expectedPageCount: pages) else {
            return XCTFail("the same file is accepted")
        }
        XCTAssertEqual(preview, try PDFCommentExporter.preview(source: source, plan: plan()))
    }

    func testAFileWithAnotherPageCountIsRefusedWithBothCounts() throws {
        let pages = try XCTUnwrap(PDFDocument(url: source)).pageCount
        XCTAssertEqual(
            PDFCommentExporter.check(chosen: source, plan: plan(), expectedPageCount: pages + 3),
            .refused(.pageCount(picked: pages, expected: pages + 3))
        )
    }

    func testAFileWhereTooFewMarginsFindTheirSentenceIsRefused() throws {
        let pages = try XCTUnwrap(PDFDocument(url: source)).pageCount
        let elsewhere = MarginCommentPlan(entries: [
            entry("m2", "Where is this from?", sentence: absentSentence, page: 1),
            entry("m4", "And this?", sentence: absentSentence, page: 0),
            entry("m1", "Cite this.", sentence: firstSentence, page: 0),
        ])
        XCTAssertEqual(
            PDFCommentExporter.check(chosen: source, plan: elsewhere, expectedPageCount: pages),
            .refused(.tooFewPlaced(placed: 1, of: 3))
        )
    }

    func testALockedFileAndAFileThatIsNotAPDFAreRefusedAsChosenFiles() throws {
        let locked = Self.folder.appending(path: "locked.pdf")
        XCTAssertEqual(PDFCommentExporter.check(chosen: locked, plan: plan(), expectedPageCount: 0), .refused(.locked))
        let notAPDF = directory.appending(path: "notes.pdf")
        try Data("not a pdf".utf8).write(to: notAPDF)
        XCTAssertEqual(PDFCommentExporter.check(chosen: notAPDF, plan: plan(), expectedPageCount: 2), .refused(.unreadable))
    }
}
