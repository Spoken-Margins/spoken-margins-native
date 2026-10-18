import XCTest
@testable import SessionKit

/// #1927: a banner that carries an action or an instruction must stay long enough for a VoiceOver or
/// Switch Control listener to find and use it.
final class FeedbackBannerAssistiveTests: XCTestCase {
    private let kinds: [FeedbackBannerPolicy.Kind] = [.success, .warning, .error]

    func testWithoutAssistiveTechnologyTheTimersAreUnchanged() {
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .success), 3)
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .success, offersAction: true), 8)
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .warning), 6)
    }

    func testWithAssistiveTechnologyEveryBannerStaysLongerThanItDoesWithout() throws {
        for kind in [FeedbackBannerPolicy.Kind.success, .warning] {
            let usual = try XCTUnwrap(FeedbackBannerPolicy.autoDismissSeconds(for: kind))
            let assisted = try XCTUnwrap(
                FeedbackBannerPolicy.autoDismissSeconds(for: kind, assistiveTechnologyRunning: true),
                "\(kind)"
            )
            XCTAssertGreaterThanOrEqual(assisted, usual * 2, "\(kind)")
        }
    }

    func testWithAssistiveTechnologyABannerWithAnActionStaysUntilDismissedOrReplaced() {
        for kind in kinds {
            XCTAssertNil(
                FeedbackBannerPolicy.autoDismissSeconds(for: kind, offersAction: true, assistiveTechnologyRunning: true),
                "\(kind)"
            )
        }
    }

    func testAnErrorNeverDismissesItselfWhateverElseIsTrue() {
        for offersAction in [false, true] {
            for assistive in [false, true] {
                XCTAssertNil(
                    FeedbackBannerPolicy.autoDismissSeconds(
                        for: .error, offersAction: offersAction, assistiveTechnologyRunning: assistive
                    ),
                    "offersAction \(offersAction), assistive \(assistive)"
                )
            }
        }
    }

    func testTheTimerWaitsWhileTheListenerTouchesOrFocusesTheBanner() {
        XCTAssertFalse(FeedbackBannerPolicy.timerIsHeld(touched: false, focused: false))
        XCTAssertTrue(FeedbackBannerPolicy.timerIsHeld(touched: true, focused: false))
        XCTAssertTrue(FeedbackBannerPolicy.timerIsHeld(touched: false, focused: true))
        XCTAssertTrue(FeedbackBannerPolicy.timerIsHeld(touched: true, focused: true))
    }

    /// Every pairing of the banner on screen and the one that follows. Only an error that offers Retry
    /// is protected, and only from a confirmation or a warning.
    func testOnlyAnErrorWithRetryRefusesAConfirmationOrWarning() {
        for current in kinds {
            for retry in [false, true] {
                for newer in kinds {
                    let expected = !(current == .error && retry && newer != .error)
                    XCTAssertEqual(
                        FeedbackBannerPolicy.mayReplace(currentKind: current, currentOffersRetry: retry, with: newer),
                        expected,
                        "\(current) retry \(retry) replaced by \(newer)"
                    )
                }
            }
        }
    }
}
