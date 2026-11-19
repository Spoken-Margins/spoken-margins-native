import XCTest
@testable import SessionKit

/// #4173 PR 2: the `share.selection` line. Counts, a place name and seconds; never an id, words or a name.
final class ShareSelectionDiagnosticsTests: XCTestCase {
    private typealias Margin = ShareSelectionDiagnostics.Margin
    private let tally = ShareStarTally(starsNow: 2, starsPlayerMargins: 1, starsElsewhere: 3, unstars: 1)

    private func fields(opened: ShareOpenedFrom = .starred, _ margins: [Margin], seconds: TimeInterval = 12, tally: ShareStarTally? = nil) -> [String: String] {
        ShareSelectionDiagnostics.fields(opened: opened, margins: margins, secondsInSheet: seconds, tally: tally ?? self.tally)
    }

    func testTwoStarredAndWrittenOutOfThreeMargins() {
        let result = fields([
            Margin(isStarred: true, isWritten: true),
            Margin(isStarred: true, isWritten: true),
            Margin(isStarred: false, isWritten: false)
        ])
        XCTAssertEqual(result, [
            "opened": "starred", "included": "2", "starredIncluded": "2", "starredLeftOut": "0", "unstarredIncluded": "0",
            "secondsInSheet": "12", "starsNow": "2", "starsPlayerMargins": "1", "starsElsewhere": "3", "unstars": "1"
        ])
    }

    func testAStarredMarginTheSenderUntickedCountsAsLeftOut() {
        let result = fields([Margin(isStarred: true, isWritten: true), Margin(isStarred: true, isWritten: false)])
        XCTAssertEqual(result["included"], "1")
        XCTAssertEqual(result["starredIncluded"], "1")
        XCTAssertEqual(result["starredLeftOut"], "1")
    }

    func testAnUnstarredMarginTheSenderTickedCountsAsUnstarredIncluded() {
        let result = fields([Margin(isStarred: true, isWritten: true), Margin(isStarred: false, isWritten: true)])
        XCTAssertEqual(result["included"], "2")
        XCTAssertEqual(result["unstarredIncluded"], "1")
        XCTAssertEqual(result["starredLeftOut"], "0")
    }

    func testAStarredMarginLeftOutForNoTranscriptCountsAsLeftOutToo() {
        // Included in the sheet but not shareable: not written, so it is "starred but not written".
        XCTAssertEqual(fields([Margin(isStarred: true, isWritten: false)])["starredLeftOut"], "1")
    }

    func testNoMarginsGivesZeros() {
        let result = fields([], tally: ShareStarTally())
        for key in ["included", "starredIncluded", "starredLeftOut", "unstarredIncluded", "starsNow", "starsPlayerMargins", "starsElsewhere", "unstars"] {
            XCTAssertEqual(result[key], "0", key)
        }
    }

    func testSecondsAreWholeAndNeverNegative() {
        XCTAssertEqual(fields([], seconds: 12.4)["secondsInSheet"], "12")
        XCTAssertEqual(fields([], seconds: 12.6)["secondsInSheet"], "13")
        XCTAssertEqual(fields([], seconds: -3)["secondsInSheet"], "0")
        XCTAssertEqual(fields([], seconds: 0)["secondsInSheet"], "0")
        XCTAssertEqual(fields([], seconds: 86_400)["secondsInSheet"], "86400")
    }

    func testEveryOpenedValueIsNamedByItsRawValue() {
        XCTAssertEqual(ShareOpenedFrom.allCases.map(\.rawValue).sorted(), ["all", "replies", "single", "starred"])
        for opened in ShareOpenedFrom.allCases {
            XCTAssertEqual(fields(opened: opened, [])["opened"], opened.rawValue)
        }
    }

    func testTheLineHoldsOnlyTheTenAgreedKeysAndOnlyNumbersOrAPlaceName() {
        let result = fields([Margin(isStarred: true, isWritten: true)])
        XCTAssertEqual(Set(result.keys), [
            "opened", "included", "starredIncluded", "starredLeftOut", "unstarredIncluded", "secondsInSheet",
            "starsNow", "starsPlayerMargins", "starsElsewhere", "unstars"
        ])
        for (key, value) in result where key != "opened" {
            XCTAssertNotNil(Int(value), "\(key) must be a plain count")
        }
        XCTAssertEqual(ShareSelectionDiagnostics.kind, "share.selection")
    }

    func testHowTheSheetWasOpened() {
        typealias D = ShareSelectionDiagnostics
        XCTAssertEqual(D.opened(isReplyBack: true, isSingleMargin: false, hasStarredCandidates: false), .replies)
        // Replies are reported as replies even when the offer holds no linked reply and preselects by stars.
        XCTAssertEqual(D.opened(isReplyBack: true, isSingleMargin: false, hasStarredCandidates: true), .replies)
        XCTAssertEqual(D.opened(isReplyBack: false, isSingleMargin: true, hasStarredCandidates: true), .single)
        XCTAssertEqual(D.opened(isReplyBack: false, isSingleMargin: true, hasStarredCandidates: false), .single)
        XCTAssertEqual(D.opened(isReplyBack: false, isSingleMargin: false, hasStarredCandidates: true), .starred)
        XCTAssertEqual(D.opened(isReplyBack: false, isSingleMargin: false, hasStarredCandidates: false), .all)
    }
}
