import XCTest
@testable import SessionKit

/// #4338, PR 6: a PDF this iPhone has no copy of. The sheet asks for the file, refuses one that is not the same PDF, and
/// fills in once a file is accepted. Decided with no PDFKit; `PDFCommentExporterTests` (Mac) runs the same rule on a real file.
final class PDFOriginalCheckTests: XCTestCase {
    private func entry(
        _ id: String, _ words: String = "Words", page: Int? = 0, status: MarginCommentPlan.Entry.Status = .included
    ) -> MarginCommentPlan.Entry {
        MarginCommentPlan.Entry(
            marginId: id, sentence: nil, sentenceText: "", precedingText: "", pageIndex: page,
            commentText: status == .included ? words : "", status: status
        )
    }

    private func plan(_ entries: [MarginCommentPlan.Entry]) -> MarginCommentPlan { MarginCommentPlan(entries: entries) }

    // MARK: No copy → Original missing

    func testNoCopyAsksForTheFileWithEveryMarginWaitingAndNothingToExport() {
        var sheet = PDFCommentExportState.waitingForOriginal(
            plan: plan([entry("a", page: 3), entry("b", page: 0), entry("c", page: 1, status: .transcriptPending)]), authorName: "Ana"
        )
        XCTAssertEqual(sheet.phase, .originalMissing)
        XCTAssertTrue(sheet.asksForFile)
        XCTAssertEqual(sheet.fileCardMessage, "This iPhone doesn't have a copy of this PDF. Choose the same file and your comments go into it.")
        XCTAssertEqual(sheet.chooseFileTitle, "Choose the PDF")
        // In page order by the item's text, each with its page and the waiting status; a Margin with no words stays left out.
        XCTAssertEqual(sheet.rows.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(sheet.rows.map(\.pageLabel), ["p. 1", "p. 2", "p. 4"])
        XCTAssertEqual(sheet.rows.map(\.status), [.waitingForPDF, .transcriptPending, .waitingForPDF])
        XCTAssertEqual(sheet.rows[0].status.words, "Waiting for the PDF")
        XCTAssertEqual(sheet.authorName, "Ana")
        XCTAssertFalse(sheet.canExport)
        XCTAssertFalse(sheet.beginExport())
        XCTAssertFalse(sheet.isEditable)
        let before = sheet
        sheet.toggle("a")
        XCTAssertEqual(sheet, before, "nothing to toggle until the file is chosen")
    }

    func testTheWaitingStatusHasItsOwnIcon() {
        let others: [PDFCommentExportState.RowStatus] = [.onItsSentence, .pageNoExactSpot(page: 0), .transcriptPending, .noTranscript]
        XCTAssertFalse(others.map(\.systemImage).contains(PDFCommentExportState.RowStatus.waitingForPDF.systemImage))
    }

    func testASheetWithAKeptCopyNeverAsksForTheFile() {
        let sheet = PDFCommentExportState(plan: plan([entry("a")]), spots: ["a": .sentence(page: 0)])
        XCTAssertFalse(sheet.asksForFile)
        XCTAssertNil(sheet.fileCardMessage)
        XCTAssertNil(sheet.chooseFileTitle)
    }

    // MARK: Choosing a file

    func testChoosingAFileChecksItOnceAndARefusalOffersAnother() {
        var sheet = PDFCommentExportState.waitingForOriginal(plan: plan([entry("a")]))
        XCTAssertTrue(sheet.beginCheckingChosenFile())
        XCTAssertEqual(sheet.phase, .loading)
        XCTAssertFalse(sheet.beginCheckingChosenFile(), "a second pick while one is checked starts nothing")
        sheet.refuseChosenFile(.pageCount(picked: 12, expected: 9))
        XCTAssertEqual(sheet.phase, .wrongFile(.pageCount(picked: 12, expected: 9)))
        XCTAssertEqual(sheet.fileCardMessage, "That isn't the same PDF: it has 12 pages and yours had 9.")
        XCTAssertEqual(sheet.chooseFileTitle, "Choose another")
        XCTAssertFalse(sheet.canExport)
        XCTAssertTrue(sheet.beginCheckingChosenFile(), "Choose another checks the next file")
    }

    func testOnlyASheetAskingForTheFileCanCheckOne() {
        var sheet = PDFCommentExportState(plan: plan([entry("a")]), spots: ["a": .sentence(page: 0)])
        XCTAssertFalse(sheet.beginCheckingChosenFile())
        sheet.refuseChosenFile(.unreadable)
        XCTAssertEqual(sheet.phase, .ready, "a refusal with no check running changes nothing")
    }

    // MARK: The rule

    func testAWrongPageCountIsRefusedWithBothCounts() {
        let refusal = PDFOriginalCheck.evaluate(
            pickedPageCount: 12, expectedPageCount: 9, plan: plan([entry("a")]), spots: ["a": .sentence(page: 0)]
        )
        XCTAssertEqual(refusal, .pageCount(picked: 12, expected: 9))
        XCTAssertEqual(PDFOriginalCheck.Refusal.pageCount(picked: 1, expected: 2).message, "That isn't the same PDF: it has 1 page and yours had 2.")
    }

    func testTooFewMarginsOnTheirSentenceIsRefused() {
        let margins = plan((1...6).map { entry("m\($0)") })
        var spots: [String: PDFCommentExportState.Spot] = ["m1": .sentence(page: 0)]
        for id in ["m2", "m3", "m4", "m5", "m6"] { spots[id] = .pageNote(page: 0) }
        let refusal = PDFOriginalCheck.evaluate(pickedPageCount: 9, expectedPageCount: 9, plan: margins, spots: spots)
        XCTAssertEqual(refusal, .tooFewPlaced(placed: 1, of: 6))
        XCTAssertEqual(refusal?.message, "Only 1 of 6 Margins found its sentence in that file. Choose the file you added.")
        XCTAssertEqual(
            PDFOriginalCheck.Refusal.tooFewPlaced(placed: 2, of: 6).message,
            "Only 2 of 6 Margins found their sentence in that file. Choose the file you added."
        )
        XCTAssertEqual(
            PDFOriginalCheck.Refusal.tooFewPlaced(placed: 0, of: 3).message,
            "None of the 3 Margins found its sentence in that file. Choose the file you added."
        )
    }

    func testHalfTheMarginsOnTheirSentenceIsEnough() {
        let margins = plan([entry("a"), entry("b"), entry("c"), entry("d")])
        let half: [String: PDFCommentExportState.Spot] = [
            "a": .sentence(page: 0), "b": .sentence(page: 1), "c": .pageNote(page: 0), "d": .pageNote(page: 2),
        ]
        XCTAssertNil(PDFOriginalCheck.evaluate(pickedPageCount: 3, expectedPageCount: 3, plan: margins, spots: half))
        var fewer = half
        fewer["b"] = .pageNote(page: 1)
        XCTAssertEqual(
            PDFOriginalCheck.evaluate(pickedPageCount: 3, expectedPageCount: 3, plan: margins, spots: fewer),
            .tooFewPlaced(placed: 1, of: 4)
        )
    }

    func testMarginsWithNoWordsAreNotCounted() {
        // One with words, on its sentence; two still transcribing. One of one is enough.
        let margins = plan([entry("a"), entry("b", status: .transcriptPending), entry("c", status: .noTranscript)])
        XCTAssertNil(PDFOriginalCheck.evaluate(pickedPageCount: 2, expectedPageCount: 2, plan: margins, spots: ["a": .sentence(page: 0)]))
    }

    func testWithNothingToPlaceThePageCountDecides() {
        let margins = plan([entry("a", status: .transcriptPending)])
        XCTAssertNil(PDFOriginalCheck.evaluate(pickedPageCount: 4, expectedPageCount: 4, plan: margins, spots: [:]))
        XCTAssertEqual(
            PDFOriginalCheck.evaluate(pickedPageCount: 5, expectedPageCount: 4, plan: margins, spots: [:]),
            .pageCount(picked: 5, expected: 4)
        )
    }

    func testAnItemWithNoRecordedPageCountIsCheckedOnPlacementOnly() {
        XCTAssertNil(PDFOriginalCheck.pageCountRefusal(pickedPageCount: 7, expectedPageCount: 0))
        XCTAssertEqual(
            PDFOriginalCheck.evaluate(pickedPageCount: 7, expectedPageCount: 0, plan: plan([entry("a")]), spots: ["a": .pageNote(page: 0)]),
            .tooFewPlaced(placed: 0, of: 1)
        )
    }

    func testWithNoPageCountAndNothingToPlaceNoFileIsAccepted() {
        let margins = plan([entry("a", status: .transcriptPending)])
        XCTAssertEqual(
            PDFOriginalCheck.evaluate(pickedPageCount: 4, expectedPageCount: 0, plan: margins, spots: [:]), .nothingToCompare
        )
        XCTAssertEqual(
            PDFOriginalCheck.Refusal.nothingToCompare.message,
            "Your Margins here have no words yet, so that file can't be checked. Try again once they're written out."
        )
    }

    // MARK: Accepted → Full

    func testAnAcceptedFileFillsTheSheetWithWhereEachCommentLanded() {
        let margins = plan([entry("a", page: 0), entry("b", page: 1), entry("c", page: 1, status: .transcriptPending)])
        let spots: [String: PDFCommentExportState.Spot] = ["a": .sentence(page: 0), "b": .pageNote(page: 1)]
        XCTAssertNil(PDFOriginalCheck.evaluate(pickedPageCount: 2, expectedPageCount: 2, plan: margins, spots: spots))
        let sheet = PDFCommentExportState(plan: margins, spots: spots, authorName: "Ana")
        XCTAssertEqual(sheet.phase, .ready)
        XCTAssertFalse(sheet.asksForFile)
        XCTAssertEqual(sheet.rows.map(\.status), [.onItsSentence, .pageNoExactSpot(page: 1), .transcriptPending])
        XCTAssertEqual(sheet.buttonTitle, "Export 2 comments")
        XCTAssertTrue(sheet.canExport)
    }
}
