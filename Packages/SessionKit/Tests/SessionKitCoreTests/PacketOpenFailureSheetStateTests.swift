import XCTest
@testable import SessionKit

/// #3801: the rules of the sheet that says a friend's link or file could not be opened.
final class PacketOpenFailureSheetStateTests: XCTestCase {
    typealias Content = PacketOpenFailureSheetContent

    /// The audit on PR #4597: a link the listener taps during a Try Again replaces the retry's open in the opener, so
    /// closing the old sheet afterwards must not stop the opener: it would drop the link just tapped, silently.
    func testALinkOpenedDuringATryAgainIsNotStoppedByClosingTheOldSheet() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        XCTAssertTrue(state.tryAgain())

        state.anotherLinkStarted()

        XCTAssertFalse(state.isRetrying, "the retry's spinner stops: its open was dropped for the new link")
        XCTAssertFalse(state.presented?.showsTryAgain ?? true, "the old link's Try Again would drop the new link too")
        XCTAssertFalse(state.tryAgain())
        XCTAssertFalse(state.close(), "Close stops nothing; the opener is running the new link")
        XCTAssertFalse(state.takeCloseNotice(), "the new link is still opening, so the drawer is not told yet (#4834)")
    }

    /// #4834 finding 1: link A failed and its sheet is up, the listener taps link B, then closes A's sheet. B is
    /// downloading, so nothing is owed to the drawer yet: telling it now would withdraw it again under B.
    func testClosingTheOldSheetWhileAnotherLinkDownloadsOwesNothing() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        state.anotherLinkStarted()

        XCTAssertFalse(state.close())

        XCTAssertFalse(state.takeCloseNotice(), "B is still opening")
    }

    /// B then fails with words of its own: that failure owes the notice again.
    func testTheSecondLinksOwnFailureOwesTheNoticeAgain() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        state.anotherLinkStarted()
        _ = state.close()
        state.present(Content(row: .serverProblem), canRetry: true)
        _ = state.close()

        XCTAssertTrue(state.takeCloseNotice())
    }

    /// B ends with no words of its own (its failure went to a banner): the old sheet closes as if the listener had and
    /// the drawer is told, as with a single link.
    func testTheSecondLinkEndingWithNoNewWordsOwesTheNoticeAgain() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()

        state.openEnded(opened: false, since: words)

        XCTAssertNil(state.presented)
        XCTAssertTrue(state.takeCloseNotice())
    }

    /// B opens: the old failure heals and nobody is told.
    func testTheSecondLinkOpeningOwesNothing() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()

        state.openEnded(opened: true, since: words)

        XCTAssertFalse(state.takeCloseNotice())
    }

    /// Neighbours: when a close owes the drawer a notice.
    func testWhenClosingOwesTheDrawerANotice() {
        typealias Steps = (inout PacketOpenFailureSheetState) -> Void
        let rows: [(String, Steps, Bool)] = [
            ("failure then close", { $0.present(Content(row: .offline), canRetry: true); _ = $0.close() }, true),
            ("failure, another link, close", { $0.present(Content(row: .offline), canRetry: true); $0.anotherLinkStarted(); _ = $0.close() }, false),
            ("failure, retry, another link, close", {
                $0.present(Content(row: .offline), canRetry: true); _ = $0.tryAgain(); $0.anotherLinkStarted(); _ = $0.close()
            }, false),
            ("another link before any failure, then a failure", {
                $0.anotherLinkStarted(); $0.present(Content(row: .offline), canRetry: false); _ = $0.close()
            }, true),
            ("failure, another link, a refused file replaces the words, close", {
                $0.present(Content(row: .offline), canRetry: true); $0.anotherLinkStarted()
                $0.present(Content(row: .serverProblem), canRetry: false); _ = $0.close()
            }, true),
        ]
        for (name, steps, owed) in rows {
            var state = PacketOpenFailureSheetState()
            steps(&state)
            XCTAssertEqual(state.takeCloseNotice(), owed, name)
        }
    }

    /// The same with no Try Again running: the old sheet's Try Again must not take the opener back from the new link.
    func testALinkOpenedWhileTheSheetIsUpTakesItsTryAgainAway() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .serverProblem), canRetry: true)
        let id = state.presented?.id

        state.anotherLinkStarted()

        XCTAssertEqual(state.presented?.id, id, "the sheet stays, so the new link's failure can swap its words")
        XCTAssertEqual(state.presented?.content.row, .serverProblem)
        XCTAssertFalse(state.tryAgain())
        state.present(Content(row: .offline), canRetry: true)
        XCTAssertTrue(state.tryAgain(), "the new link's own failure brings its own Try Again")
    }

    func testClosingDuringATryAgainStopsThatOpenAndTellsTheDrawerOnce() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        XCTAssertTrue(state.tryAgain())
        XCTAssertFalse(state.tryAgain(), "a second tap while one runs does nothing")

        XCTAssertTrue(state.close())

        XCTAssertFalse(state.isRetrying)
        XCTAssertTrue(state.takeCloseNotice())
        XCTAssertFalse(state.takeCloseNotice(), "once")
    }

    func testTryAgainNeedsARetryableRowAndSomethingToRun() {
        var expired = PacketOpenFailureSheetState()
        expired.present(Content(row: .expired), canRetry: true)
        XCTAssertFalse(expired.tryAgain())

        var nothingToRun = PacketOpenFailureSheetState()
        nothingToRun.present(Content(row: .offline), canRetry: false)
        XCTAssertFalse(nothingToRun.presented?.showsTryAgain ?? true)
        XCTAssertFalse(nothingToRun.tryAgain())
    }

    func testASecondFailureSwapsTheWordsOnTheSameSheet() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        let id = state.presented?.id
        XCTAssertTrue(state.tryAgain())

        state.present(Content(row: .expired), canRetry: false)

        XCTAssertEqual(state.presented?.id, id)
        XCTAssertEqual(state.presented?.content.row, .expired)
        XCTAssertFalse(state.isRetrying)
    }

    func testATryAgainThatWorksClosesTheSheetAndTellsNobody() {
        var state = PacketOpenFailureSheetState()
        state.present(Content(row: .offline), canRetry: true)
        let began = state.generation
        XCTAssertTrue(state.tryAgain())

        state.openEnded(opened: true, since: began)

        XCTAssertNil(state.presented)
        XCTAssertFalse(state.isRetrying)
        XCTAssertFalse(state.takeCloseNotice())
    }

    func testAnOpenThatEndsWithoutNewWordsClosesTheStaleSheetAndOneWithNewWordsLeavesThem() {
        var stale = PacketOpenFailureSheetState()
        stale.present(Content(row: .offline), canRetry: true)
        let began = stale.generation
        XCTAssertTrue(stale.tryAgain())
        stale.openEnded(opened: false, since: began)
        XCTAssertNil(stale.presented, "a banner behind a sheet cannot be read")
        XCTAssertFalse(stale.isRetrying)
        XCTAssertTrue(stale.takeCloseNotice())

        var fresh = PacketOpenFailureSheetState()
        fresh.present(Content(row: .offline), canRetry: true)
        let before = fresh.generation
        fresh.present(Content(row: .expired), canRetry: false)
        fresh.openEnded(opened: false, since: before)
        XCTAssertEqual(fresh.presented?.content.row, .expired)
    }
}
