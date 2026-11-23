import XCTest
@testable import SessionKit

/// #3801 and #4834: the rules of the sheet that says a friend's link or file could not be opened, and of when the
/// first-launch drawer is told (only by `sheetDismissed()` or by `openEnded`, once, never while an open is running).
final class PacketOpenFailureSheetStateTests: XCTestCase {
    typealias Content = PacketOpenFailureSheetContent
    typealias State = PacketOpenFailureSheetState

    /// The audit on PR #4597: a link the listener taps during a Try Again replaces the retry's open in the opener, so
    /// closing the old sheet afterwards must not stop the opener: it would drop the link just tapped, silently.
    func testALinkOpenedDuringATryAgainIsNotStoppedByClosingTheOldSheet() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        XCTAssertTrue(state.tryAgain())

        state.anotherLinkStarted()

        XCTAssertFalse(state.isRetrying, "the retry's spinner stops: its open was dropped for the new link")
        XCTAssertFalse(state.presented?.showsTryAgain ?? true, "the old link's Try Again would drop the new link too")
        XCTAssertFalse(state.tryAgain())
        XCTAssertFalse(state.close(), "Close stops nothing; the opener is running the new link")
        XCTAssertFalse(state.sheetDismissed(), "the new link is still opening, so the drawer is not told yet (#4834)")
    }

    /// The same with no Try Again running: the old sheet's Try Again must not take the opener back from the new link.
    func testALinkOpenedWhileTheSheetIsUpTakesItsTryAgainAway() {
        var state = State()
        state.present(Content(row: .serverProblem), canRetry: true)
        let id = state.presented?.id

        state.anotherLinkStarted()

        XCTAssertEqual(state.presented?.id, id, "the sheet stays, so the new link's failure can swap its words")
        XCTAssertEqual(state.presented?.content.row, .serverProblem)
        XCTAssertFalse(state.tryAgain())
        state.present(Content(row: .offline), canRetry: true, endsOpen: true)
        XCTAssertTrue(state.tryAgain(), "the new link's own failure brings its own Try Again")
    }

    func testClosingDuringATryAgainStopsThatOpenAndTellsTheDrawerOnce() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        XCTAssertTrue(state.tryAgain())
        XCTAssertFalse(state.tryAgain(), "a second tap while one runs does nothing")

        XCTAssertTrue(state.close())

        XCTAssertFalse(state.isRetrying)
        XCTAssertTrue(state.sheetDismissed())
        XCTAssertFalse(state.sheetDismissed(), "once")
    }

    /// #4834 finding 1: link A failed and its sheet is up, the listener taps link B, then closes A's sheet. B is
    /// downloading, so nothing is owed to the drawer yet: telling it now would withdraw it again under B.
    func testClosingTheOldSheetWhileAnotherLinkDownloadsOwesNothingYet() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        state.anotherLinkStarted()

        XCTAssertFalse(state.close())

        XCTAssertFalse(state.sheetDismissed(), "B is still opening")
    }

    /// B then fails with words of its own: that failure owes the notice, handed out when its sheet is gone.
    func testTheSecondLinksOwnFailureOwesTheNoticeOnceItsSheetIsGone() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        state.anotherLinkStarted()
        _ = state.close()
        XCTAssertFalse(state.sheetDismissed())
        state.present(Content(row: .serverProblem), canRetry: true, endsOpen: true)
        _ = state.close()

        XCTAssertTrue(state.sheetDismissed())
    }

    /// B ends with no words of its own (its failure went to a banner) while the old sheet is still up: the sheet closes
    /// as if the listener had, and the drawer is told when it has gone, not before.
    func testTheSecondLinkEndingWithNoNewWordsClosesTheSheetAndTellsTheDrawerAfterItLeaves() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()

        XCTAssertFalse(state.openEnded(opened: false, since: words), "the sheet is still leaving")

        XCTAssertNil(state.presented)
        XCTAssertTrue(state.sheetDismissed())
    }

    /// #4834: B ends as a banner after the old sheet has fully gone: the notice comes straight from `openEnded`.
    func testTheSecondLinkEndingAsABannerAfterTheOldSheetWentTellsTheDrawerFromOpenEnded() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()
        _ = state.close()
        XCTAssertFalse(state.sheetDismissed(), "B is still opening")

        XCTAssertTrue(state.openEnded(opened: false, since: words))

        XCTAssertFalse(state.sheetDismissed(), "once")
        XCTAssertFalse(state.openEnded(opened: false, since: words), "once")
    }

    /// The old sheet is closed but still animating out when B ends: the drawer waits for the dismissal.
    func testTheSecondLinkEndingWhileTheOldSheetIsLeavingWaitsForTheDismissal() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()
        _ = state.close()

        XCTAssertFalse(state.openEnded(opened: false, since: words))
        XCTAssertTrue(state.sheetDismissed())
    }

    /// With no failure ever owed, a link that ends as a banner owes nothing.
    func testALinkEndingAsABannerWithNoFailureBeforeItOwesNothing() {
        var state = State()
        let words = state.generation
        state.anotherLinkStarted()

        XCTAssertFalse(state.openEnded(opened: false, since: words))
        XCTAssertFalse(state.sheetDismissed())
    }

    /// B opens after the old sheet closed: nothing is owed, and a later banner from an unrelated open owes nothing.
    func testTheSecondLinkOpeningAfterTheOldSheetClosedOwesNothing() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()
        _ = state.close()

        XCTAssertFalse(state.openEnded(opened: true, since: words))
        XCTAssertFalse(state.openEnded(opened: false, since: words))
        XCTAssertFalse(state.sheetDismissed())
    }

    /// B opens while the old sheet is up: the old failure heals and nobody is told.
    func testTheSecondLinkOpeningOwesNothing() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()

        state.openEnded(opened: true, since: words)

        XCTAssertFalse(state.sheetDismissed())
    }

    /// #4834 second path: a Try Again is running and the file it opened is refused. The refusal puts its words up (it
    /// is not the end of the open: `openEnded` follows), so closing that sheet meanwhile owes nothing yet, and the
    /// notice comes from `openEnded` once the open has ended.
    func testARefusedFileDuringATryAgainOwesTheNoticeOnlyWhenTheOpenEnds() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        XCTAssertTrue(state.tryAgain())

        state.present(Content(row: .expired), canRetry: false)
        XCTAssertFalse(state.isRetrying)
        XCTAssertFalse(state.close())
        XCTAssertFalse(state.sheetDismissed(), "the open has not ended")

        XCTAssertTrue(state.openEnded(opened: false, since: words))
    }

    /// The same when the sheet is still up as the open ends: the dismissal hands the notice out.
    func testARefusedFileDuringATryAgainWithTheSheetStillUpWaitsForTheDismissal() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        XCTAssertTrue(state.tryAgain())
        state.present(Content(row: .expired), canRetry: false)

        XCTAssertFalse(state.openEnded(opened: false, since: words), "the sheet is up with new words")
        XCTAssertFalse(state.sheetDismissed(), "still up")
        _ = state.close()
        XCTAssertTrue(state.sheetDismissed())
    }

    /// A refused file for a link opened over the old sheet behaves the same.
    func testARefusedFileForTheSecondLinkOwesTheNoticeOnlyWhenItsOpenEnds() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let words = state.generation
        state.anotherLinkStarted()
        state.present(Content(row: .expired), canRetry: false)
        _ = state.close()
        XCTAssertFalse(state.sheetDismissed(), "B's open has not ended")

        XCTAssertTrue(state.openEnded(opened: false, since: words))
    }

    func testTryAgainNeedsARetryableRowAndSomethingToRun() {
        var expired = State()
        expired.present(Content(row: .expired), canRetry: true)
        XCTAssertFalse(expired.tryAgain())

        var nothingToRun = State()
        nothingToRun.present(Content(row: .offline), canRetry: false)
        XCTAssertFalse(nothingToRun.presented?.showsTryAgain ?? true)
        XCTAssertFalse(nothingToRun.tryAgain())
    }

    func testASecondFailureSwapsTheWordsOnTheSameSheet() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let id = state.presented?.id
        XCTAssertTrue(state.tryAgain())

        state.present(Content(row: .expired), canRetry: false)

        XCTAssertEqual(state.presented?.id, id)
        XCTAssertEqual(state.presented?.content.row, .expired)
        XCTAssertFalse(state.isRetrying)
    }

    func testATryAgainThatWorksClosesTheSheetAndTellsNobody() {
        var state = State()
        state.present(Content(row: .offline), canRetry: true)
        let began = state.generation
        XCTAssertTrue(state.tryAgain())

        state.openEnded(opened: true, since: began)

        XCTAssertNil(state.presented)
        XCTAssertFalse(state.isRetrying)
        XCTAssertFalse(state.sheetDismissed())
    }

    func testAnOpenThatEndsWithoutNewWordsClosesTheStaleSheetAndOneWithNewWordsLeavesThem() {
        var stale = State()
        stale.present(Content(row: .offline), canRetry: true)
        let began = stale.generation
        XCTAssertTrue(stale.tryAgain())
        stale.openEnded(opened: false, since: began)
        XCTAssertNil(stale.presented, "a banner behind a sheet cannot be read")
        XCTAssertFalse(stale.isRetrying)
        XCTAssertTrue(stale.sheetDismissed())

        var fresh = State()
        fresh.present(Content(row: .offline), canRetry: true)
        let before = fresh.generation
        fresh.present(Content(row: .expired), canRetry: false)
        fresh.openEnded(opened: false, since: before)
        XCTAssertEqual(fresh.presented?.content.row, .expired)
    }

    // MARK: Transition table

    /// Every event, in every situation that matters, and what the drawer is told. A step is `(event, notice)`: the notice
    /// is what that call returned (events with no return value expect false). A row's last step is the case.
    private enum Event {
        case failure            // a failure with words, from a fresh link (ends its open)
        case refusedFile        // a refused file: words, but its open ends by openEnded
        case anotherLink        // the listener taps a second link
        case tryAgain
        case close              // OK, Close or a swipe
        case dismissed          // the sheet's onDismiss
        case openEndedBanner    // the open ends, the failure went to a banner (no new words)
        case openEndedOpened    // the open ends, it opened
    }

    private func run(_ events: [Event], file: StaticString = #filePath, line: UInt = #line) -> [Bool] {
        var state = State()
        var words = state.generation
        var notices: [Bool] = []
        for event in events {
            switch event {
            case .failure:
                state.present(Content(row: .offline), canRetry: true, endsOpen: true)
                notices.append(false)
            case .refusedFile:
                state.present(Content(row: .expired), canRetry: false)
                notices.append(false)
            case .anotherLink:
                words = state.generation
                state.anotherLinkStarted()
                notices.append(false)
            case .tryAgain:
                words = state.generation
                _ = state.tryAgain()
                notices.append(false)
            case .close:
                _ = state.close()
                notices.append(false)
            case .dismissed:
                notices.append(state.sheetDismissed())
            case .openEndedBanner:
                notices.append(state.openEnded(opened: false, since: words))
            case .openEndedOpened:
                notices.append(state.openEnded(opened: true, since: words))
            }
        }
        return notices
    }

    func testTheNoticeTransitionTable() {
        typealias Row = (name: String, events: [Event], notices: [Int])  // indexes of the steps that hand the notice out
        let rows: [Row] = [
            ("failure, close, dismissed", [.failure, .close, .dismissed], [2]),
            ("dismissed before any close does nothing", [.failure, .dismissed], []),
            ("close then dismissed twice: once", [.failure, .close, .dismissed, .dismissed], [2]),
            ("another link, close, dismissed: B still opening", [.failure, .anotherLink, .close, .dismissed], []),
            ("another link, close, dismissed, B banner: notice from openEnded", [.failure, .anotherLink, .close, .dismissed, .openEndedBanner], [4]),
            ("another link, close, B banner before dismissed: waits for the dismissal", [.failure, .anotherLink, .close, .openEndedBanner, .dismissed], [4]),
            ("another link, B banner with the sheet up, then dismissed", [.failure, .anotherLink, .openEndedBanner, .dismissed], [3]),
            ("another link, close, dismissed, B opens: nothing", [.failure, .anotherLink, .close, .dismissed, .openEndedOpened, .dismissed], []),
            ("another link, B opens with the sheet up: nothing", [.failure, .anotherLink, .openEndedOpened, .dismissed], []),
            ("another link, close, B fails with words, close, dismissed", [.failure, .anotherLink, .close, .dismissed, .failure, .close, .dismissed], [6]),
            ("try again, refused file, close, dismissed: the open has not ended", [.failure, .tryAgain, .refusedFile, .close, .dismissed], []),
            ("try again, refused file, close, dismissed, open ends", [.failure, .tryAgain, .refusedFile, .close, .dismissed, .openEndedBanner], [5]),
            ("try again, refused file, open ends, close, dismissed", [.failure, .tryAgain, .refusedFile, .openEndedBanner, .close, .dismissed], [5]),
            ("try again, close stops it: dismissed hands it out", [.failure, .tryAgain, .close, .dismissed], [3]),
            ("try again works: nothing", [.failure, .tryAgain, .openEndedOpened, .dismissed], []),
            ("two links overlap: A, B, B refused, B ends, close, dismissed", [.failure, .anotherLink, .refusedFile, .openEndedBanner, .close, .dismissed], [5]),
            ("two links overlap: A, B, C (another), close, dismissed: still running", [.failure, .anotherLink, .anotherLink, .close, .dismissed], []),
            ("a banner with no failure ever: nothing", [.anotherLink, .openEndedBanner, .dismissed], []),
            ("a failure with no second link, close, dismissed", [.failure, .close, .dismissed, .openEndedBanner], [2]),
        ]
        for row in rows {
            let notices = run(row.events)
            let got = notices.enumerated().filter { $0.element }.map(\.offset)
            XCTAssertEqual(got, row.notices, row.name)
        }
    }
}
