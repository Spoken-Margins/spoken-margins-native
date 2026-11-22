import XCTest
@testable import SessionKit

/// #4338, PR 5: what the "PDF with your Margins" sheet lists and offers, decided with no PDFKit.
final class PDFCommentExportStateTests: XCTestCase {
    private func entry(
        _ id: String, _ words: String, page: Int? = 0, status: MarginCommentPlan.Entry.Status = .included
    ) -> MarginCommentPlan.Entry {
        MarginCommentPlan.Entry(
            marginId: id, sentence: nil, sentenceText: "", precedingText: "", pageIndex: page,
            commentText: status == .included ? words : "", status: status
        )
    }

    private func state(
        _ entries: [MarginCommentPlan.Entry], spots: [String: PDFCommentExportState.Spot]? = [:], author: String = ""
    ) -> PDFCommentExportState {
        PDFCommentExportState(plan: MarginCommentPlan(entries: entries), spots: spots, authorName: author)
    }

    // MARK: Rows and statuses

    func testEachRowSaysWhereItsCommentLandsInWordsAndAnIcon() {
        let sheet = state(
            [entry("a", "Cite this", page: 3), entry("b", "Here", page: 3), entry("c", "", page: 4, status: .transcriptPending), entry("d", "", page: nil, status: .noTranscript)],
            spots: ["a": .sentence(page: 3), "b": .pageNote(page: 3)]
        )
        XCTAssertEqual(sheet.rows.map(\.status), [.onItsSentence, .pageNoExactSpot(page: 3), .transcriptPending, .noTranscript])
        XCTAssertEqual(sheet.rows.map(\.status.words), [
            "On its sentence", "On page 4, no exact spot", "Left out: transcript not ready yet", "Left out: no transcript",
        ])
        XCTAssertEqual(Set(sheet.rows.map(\.status.systemImage)).count, 4, "each status has its own icon")
        XCTAssertEqual(sheet.rows.map(\.pageLabel), ["p. 4", "p. 4", "p. 5", nil])
    }

    func testTheRowShowsThePageTheCommentLandedOnNotOnlyTheHint() {
        let sheet = state([entry("a", "Words", page: 2)], spots: ["a": .sentence(page: 3)])
        XCTAssertEqual(sheet.rows[0].pageLabel, "p. 4")
    }

    func testRowsAreInPageOrderAndKeepThePlansOrderWithinAPage() {
        let sheet = state([entry("z", "one", page: 0), entry("a", "two", page: 1), entry("m", "three", page: 1)])
        XCTAssertEqual(sheet.rows.map(\.id), ["z", "a", "m"])
    }

    func testACommentFoundOnThePageBeforeItsHintStillReadsInPageOrder() {
        // The locator may land a later sentence on the page before its hint: the list follows where comments land.
        let sheet = state(
            [entry("early", "one", page: 3), entry("late", "two", page: 4), entry("scan", "three", page: 7)],
            spots: ["early": .sentence(page: 3), "late": .sentence(page: 2), "scan": .pageNote(page: 7)]
        )
        XCTAssertEqual(sheet.rows.map(\.id), ["late", "early", "scan"])
        XCTAssertEqual(sheet.rows.map(\.pageLabel), ["p. 3", "p. 4", "p. 8"])
    }

    func testARowWithNoPageKnownGoesLast() {
        let sheet = state([entry("none", "", page: nil, status: .noTranscript), entry("a", "x", page: 5), entry("b", "y", page: 1)])
        XCTAssertEqual(sheet.rows.map(\.id), ["b", "a", "none"])
    }

    func testAMarginWithNoWordsShowsAPlaceholderNotABlankRow() {
        let sheet = state([entry("a", "", status: .transcriptPending)])
        XCTAssertEqual(sheet.rows[0].text, "Spoken Margin")
    }

    func testAMarginTheLocatorNeverReportedIsOnItsHintedPageWithNoExactSpot() {
        let sheet = state([entry("a", "Words", page: 5)], spots: [:])
        XCTAssertEqual(sheet.rows[0].status, .pageNoExactSpot(page: 5))
    }

    // MARK: Inclusion

    func testEveryIncludableRowStartsIncludedAndOthersNever() {
        let sheet = state([entry("a", "x"), entry("b", "", status: .transcriptPending), entry("c", "", status: .noTranscript)])
        XCTAssertEqual(sheet.includedIds, ["a"])
        XCTAssertEqual(sheet.rows.map(\.isIncluded), [true, false, false])
    }

    func testToggleLeavesARowOutAndBringsItBack() {
        var sheet = state([entry("a", "x"), entry("b", "y")])
        sheet.toggle("a")
        XCTAssertEqual(sheet.includedIds, ["b"])
        sheet.toggle("a")
        XCTAssertEqual(sheet.includedIds, ["a", "b"])
    }

    func testAMarginWithNoWordsCannotBeIncludedByATap() {
        var sheet = state([entry("a", "", status: .transcriptPending)])
        sheet.toggle("a")
        XCTAssertEqual(sheet.includedCount, 0)
    }

    func testToggleOfAnUnknownIdChangesNothing() {
        var sheet = state([entry("a", "x")])
        let before = sheet
        sheet.toggle("nope")
        XCTAssertEqual(sheet, before)
    }

    // MARK: The button

    func testTheButtonCountsIncludedRowsAndSaysCommentOnceForOne() {
        var sheet = state([entry("a", "x"), entry("b", "y"), entry("c", "z")])
        XCTAssertEqual(sheet.buttonTitle, "Export 3 comments")
        sheet.toggle("a")
        sheet.toggle("b")
        XCTAssertEqual(sheet.buttonTitle, "Export 1 comment")
        sheet.toggle("c")
        XCTAssertEqual(sheet.buttonTitle, "Nothing to export")
        XCTAssertFalse(sheet.canExport)
    }

    func testAnItemWithNoMarginsAtAllHasNothingToExport() {
        let sheet = state([])
        XCTAssertEqual(sheet.buttonTitle, "Nothing to export")
        XCTAssertFalse(sheet.canExport)
    }

    func testNothingExportsWhileThePlacementIsStillRunning() {
        var sheet = state([entry("a", "x")], spots: nil)
        XCTAssertEqual(sheet.phase, .loading)
        XCTAssertFalse(sheet.canExport)
        XCTAssertFalse(sheet.beginExport())
    }

    func testASecondTapOnExportStartsNothing() {
        var sheet = state([entry("a", "x")])
        XCTAssertTrue(sheet.beginExport())
        XCTAssertEqual(sheet.phase, .exporting)
        XCTAssertEqual(sheet.buttonTitle, "Placing comments…")
        XCTAssertFalse(sheet.beginExport(), "one build at a time")
    }

    func testRowsAndNameAreLockedWhileExporting() {
        var sheet = state([entry("a", "x"), entry("b", "y")])
        XCTAssertTrue(sheet.beginExport())
        sheet.toggle("a")
        XCTAssertEqual(sheet.includedIds, ["a", "b"])
        XCTAssertFalse(sheet.isEditable)
    }

    func testACancelledShareSheetReturnsToTheFullListWithNothingChanged() {
        var sheet = state([entry("a", "x"), entry("b", "y")])
        sheet.toggle("b")
        XCTAssertTrue(sheet.beginExport())
        sheet.endExport(failed: false)
        XCTAssertEqual(sheet.phase, .ready)
        XCTAssertEqual(sheet.includedIds, ["a"], "the choices stay")
        XCTAssertTrue(sheet.canExport)
    }

    func testAFailedWriteShowsTheFailureUntilTryAgain() {
        var sheet = state([entry("a", "x")])
        XCTAssertTrue(sheet.beginExport())
        sheet.endExport(failed: true)
        XCTAssertEqual(sheet.phase, .writeFailed)
        XCTAssertFalse(sheet.canExport)
        sheet.dismissFailure()
        XCTAssertEqual(sheet.phase, .ready)
        XCTAssertTrue(sheet.beginExport())
    }

    func testEndingAnExportThatNeverStartedDoesNothing() {
        var sheet = state([entry("a", "x")])
        sheet.endExport(failed: true)
        XCTAssertEqual(sheet.phase, .ready)
    }

    func testALockedFileOffersNothing() {
        var sheet = state([entry("a", "x")])
        sheet.markLocked()
        XCTAssertFalse(sheet.canExport)
        XCTAssertFalse(sheet.beginExport())
        XCTAssertEqual(PDFCommentExportState.lockedMessage, "This PDF is locked, so comments can't be added to it.")
    }

    func testAFileThatCannotBeReadOffersNothing() {
        var sheet = state([entry("a", "x")])
        sheet.markUnreadable()
        XCTAssertEqual(sheet.phase, .unreadable)
        XCTAssertFalse(sheet.canExport)
        XCTAssertFalse(sheet.beginExport())
        XCTAssertFalse(sheet.isEditable)
        XCTAssertEqual(PDFCommentExportState.unreadableMessage, "Couldn't read this PDF. Your Margins and the PDF are unchanged.")
    }

    // MARK: Finished or unfinished item (Starting state `finished`)

    func testWhatIsListedDoesNotDependOnHowFarTheItemWasHeard() {
        // The plan is made from the item's Margins and text alone; the sheet takes nothing about progress.
        let entries = [entry("a", "x"), entry("b", "y")]
        XCTAssertEqual(state(entries).rows, state(entries).rows)
        XCTAssertEqual(state(entries).includedIds, ["a", "b"])
    }

    // MARK: Messages

    func testDoneMessageNamesTheCount() {
        XCTAssertEqual(PDFCommentExportState.doneMessage(count: 1), "Exported 1 comment.")
        XCTAssertEqual(PDFCommentExportState.doneMessage(count: 6), "Exported 6 comments.")
    }

    func testLeadLineNamesTheTitleAndPromisesTheOriginalStaysAsItIs() {
        let line = PDFCommentExportState.leadLine(title: "On Sleep")
        XCTAssertTrue(line.contains("“On Sleep”"))
        XCTAssertTrue(line.contains("The original stays as it is."))
    }

    // MARK: Name on comments

    func testTheAuthorIsTrimmedAndOneLine() {
        let table: [(String, String)] = [
            ("", ""),
            ("   ", ""),
            ("Ada", "Ada"),
            ("  Ada Lovelace \n", "Ada Lovelace"),
            ("Ada\nLovelace", "Ada Lovelace"),
            ("Ada\r\nLovelace", "Ada Lovelace"),
            ("Dr. Zoë Müller", "Dr. Zoë Müller"),
        ]
        for (typed, written) in table {
            XCTAssertEqual(PDFCommentExportState.normalizedAuthor(typed), written, "typed: \(typed.debugDescription)")
        }
    }

    func testAVeryLongAuthorIsCapped() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(PDFCommentExportState.normalizedAuthor(long).count, PDFCommentExportState.authorNameLimit)
    }

    func testAnEmptyNameMeansNoAuthor() {
        XCTAssertEqual(state([entry("a", "x")], author: "  ").authorForComments, "")
        XCTAssertEqual(state([entry("a", "x")], author: " Ada ").authorForComments, "Ada")
    }

    // MARK: File name

    func testTheFileNameIsTheTitleWithMarginsAndPDF() {
        let table: [(String, String)] = [
            ("On Sleep", "On Sleep (with Margins).pdf"),
            ("  On   Sleep  ", "On Sleep (with Margins).pdf"),
            ("A/B: C\\D", "A B C D (with Margins).pdf"),
            ("Line\none\ttwo", "Line one two (with Margins).pdf"),
            ("Bell\u{07}ring", "Bell ring (with Margins).pdf"),
            ("zero\u{200B}width", "zero width (with Margins).pdf"),
            ("..hidden", "hidden (with Margins).pdf"),
            ("", "PDF (with Margins).pdf"),
            ("   ", "PDF (with Margins).pdf"),
            ("///", "PDF (with Margins).pdf"),
            ("Café déjà vu", "Café déjà vu (with Margins).pdf"),
            ("Paper (draft 2)", "Paper (draft 2) (with Margins).pdf"),
        ]
        for (title, expected) in table {
            XCTAssertEqual(PDFCommentExportFileName.make(title: title), expected, "title: \(title.debugDescription)")
        }
    }

    func testALongTitleIsCappedAndNeverMakesAPathOrAHiddenFile() {
        let name = PDFCommentExportFileName.make(title: String(repeating: "x", count: 400))
        XCTAssertEqual(name.count, PDFCommentExportFileName.titleLimit + PDFCommentExportFileName.suffix.count + ".pdf".count)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.hasPrefix("."))
        let trailing = PDFCommentExportFileName.make(title: String(repeating: "x", count: 119) + " tail")
        XCTAssertTrue(trailing.hasSuffix(" (with Margins).pdf"))
        XCTAssertFalse(trailing.contains(" " + PDFCommentExportFileName.suffix), "no space left dangling before the suffix")
    }
}
