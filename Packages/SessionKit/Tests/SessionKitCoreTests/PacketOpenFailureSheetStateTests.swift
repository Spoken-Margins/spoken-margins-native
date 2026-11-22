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
        XCTAssertTrue(state.takeCloseNotice())
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
