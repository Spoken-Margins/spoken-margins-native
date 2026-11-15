import XCTest
@testable import SessionKit

/// #2997 PR 4: the words a pick from Files leaves when at least one file was handled as a transcript.
final class TranscriptPickBannerTests: XCTestCase {
    private func make(
        added: [(String, String)] = [], refusals: [TranscriptImportMessage] = [], documents: Int = 0,
        documentFailures: [String] = [], picked: Int
    ) -> TranscriptPickBanner.Banner {
        TranscriptPickBanner.make(
            added: added.map { (itemId: $0.0, title: $0.1) }, refusals: refusals, documentsImported: documents,
            documentFailureNames: documentFailures, pickedCount: picked)
    }

    func testOneTranscriptAloneGetsTheStandardAddedBannerWithPlayNow() {
        XCTAssertEqual(make(added: [("a", "Budget sync")], picked: 1), .addedOne(itemId: "a", title: "Budget sync"))
    }

    func testOneRefusedFileAloneGetsItsOwnSentence() {
        let refusal = TranscriptImportMessage(.empty, fileName: "zero.vtt")
        XCTAssertEqual(make(refusals: [refusal], picked: 1), .failure("\u{201C}zero.vtt\u{201D} is empty, so nothing was added."))
    }

    func testSeveralFilesGetOneSummaryThatCountsTranscriptsAndDocumentsTogether() {
        XCTAssertEqual(make(added: [("a", "One"), ("b", "Two")], documents: 1, picked: 3), .confirmation("Imported 3 files."))
        XCTAssertEqual(make(added: [("a", "One")], documents: 1, picked: 2), .confirmation("Imported 2 files."))
    }

    func testTheSameTranscriptPickedTwiceCountsOnce() {
        XCTAssertEqual(make(added: [("a", "One"), ("a", "One")], documents: 1, picked: 3), .confirmation("Imported 2 files."))
        XCTAssertEqual(make(added: [("a", "One"), ("a", "One")], picked: 2), .confirmation("Imported 1 file."))
    }

    func testFailuresAreNamedAndCounted() {
        let refusal = TranscriptImportMessage(.tooLarge, fileName: "big.vtt")
        XCTAssertEqual(
            make(added: [("a", "One")], refusals: [refusal], documentFailures: ["broken.pdf"], picked: 3),
            .confirmation("Imported 1 file. 2 couldn't be added: big.vtt, broken.pdf."))
    }

    func testAtMostThreeNamesAreListedThenAndKMore() {
        let refusals = (1...5).map { TranscriptImportMessage(.empty, fileName: "f\($0).vtt") }
        XCTAssertEqual(
            make(added: [("a", "One")], refusals: refusals, picked: 6),
            .confirmation("Imported 1 file. 5 couldn't be added: f1.vtt, f2.vtt, f3.vtt and 2 more."))
        XCTAssertEqual(
            make(added: [("a", "One")], refusals: Array(refusals.prefix(3)), picked: 4),
            .confirmation("Imported 1 file. 3 couldn't be added: f1.vtt, f2.vtt, f3.vtt."))
    }

    func testWhenNothingWasAddedTheBannerSaysSoAndIsAFailure() {
        let refusals = [TranscriptImportMessage(.empty, fileName: "a.vtt"), TranscriptImportMessage(.noTimedLines, fileName: "b.srt")]
        XCTAssertEqual(make(refusals: refusals, picked: 2), .failure("No files were added. 2 couldn't be added: a.vtt, b.srt."))
    }

    func testANameWithLineBreaksOrAHugeLengthIsListedAsOneShortLine() {
        let nasty = "bad\nname\r\twith   gaps.vtt"
        let huge = String(repeating: "x", count: 200) + ".vtt"
        let banner = make(added: [("a", "One")], refusals: [], documentFailures: [nasty, huge], picked: 3)
        guard case .confirmation(let text) = banner else { return XCTFail("expected a confirmation") }
        XCTAssertFalse(text.contains("\n"))
        XCTAssertTrue(text.contains("bad name with gaps.vtt"))
        XCTAssertTrue(text.count < 200, "the long name is shortened")
    }

    func testAPickOfOneDocumentOnlyFallsToTheSummaryWhenATranscriptWasHandledAlongsideIt() {
        // One transcript refused, one document added: several files, so a summary rather than a lone sentence.
        let refusal = TranscriptImportMessage(.docxNotATranscript, fileName: "essay.docx")
        XCTAssertEqual(
            make(refusals: [refusal], documents: 1, picked: 2),
            .confirmation("Imported 1 file. 1 couldn't be added: essay.docx."))
    }
}
