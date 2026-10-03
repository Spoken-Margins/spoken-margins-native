import XCTest
@testable import SessionKit

/// #310: error banners dismissed themselves after 6 seconds, and the failure couldn't be read again.
final class FeedbackBannerPolicyTests: XCTestCase {
    func testErrorBannersStayUntilTheListenerDismissesThem() {
        XCTAssertNil(FeedbackBannerPolicy.autoDismissSeconds(for: .error))
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .success), 3)
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .warning), 6)
    }

    func testAConfirmationDoesNotCoverAnErrorThatOffersRetry() {
        XCTAssertFalse(FeedbackBannerPolicy.mayReplace(currentKind: .error, currentOffersRetry: true, with: .success))
        XCTAssertFalse(FeedbackBannerPolicy.mayReplace(currentKind: .error, currentOffersRetry: true, with: .warning))
        XCTAssertTrue(FeedbackBannerPolicy.mayReplace(currentKind: .error, currentOffersRetry: true, with: .error))
    }

    func testOtherBannersGiveWayToNewerEvents() {
        XCTAssertTrue(FeedbackBannerPolicy.mayReplace(currentKind: .error, currentOffersRetry: false, with: .success))
        XCTAssertTrue(FeedbackBannerPolicy.mayReplace(currentKind: .success, currentOffersRetry: false, with: .warning))
        XCTAssertTrue(FeedbackBannerPolicy.mayReplace(currentKind: .warning, currentOffersRetry: false, with: .error))
    }

    func testAnItemKeepsItsLastFailureUntilCleared() {
        var log = ItemFailureLog()
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 200)
        log.record("Download failed.", itemId: "item-a", at: first)
        log.record("Preparation failed.", itemId: "item-a", at: second)
        log.record("Other item failed.", itemId: "item-b", at: first)
        log.record("No item.", itemId: "", at: first)

        XCTAssertEqual(log.lastFailure(itemId: "item-a"), .init(message: "Preparation failed.", occurredAt: second))
        XCTAssertEqual(log.lastFailure(itemId: "item-b")?.message, "Other item failed.")
        XCTAssertNil(log.lastFailure(itemId: ""))

        log.clear(itemId: "item-a")
        XCTAssertNil(log.lastFailure(itemId: "item-a"))
        XCTAssertEqual(log.lastFailure(itemId: "item-b")?.message, "Other item failed.")
    }

    func testSummaryFailureKeepsItsOriginWhenNoItemIsVisible() {
        var log = ItemFailureLog()
        let failedAt = Date(timeIntervalSince1970: 425)
        log.record("Summary failed.", itemId: "summary-item", visibleItemId: "", at: failedAt)

        XCTAssertEqual(log.lastFailure(itemId: "summary-item"),
                       .init(message: "Summary failed.", occurredAt: failedAt))
        XCTAssertNil(log.lastFailure(itemId: ""))
    }

    func testSummaryFailureKeepsItsOriginWhenAnotherItemIsVisible() {
        var log = ItemFailureLog()
        let failedAt = Date(timeIntervalSince1970: 425)
        log.record("Summary failed.", itemId: "summary-item", visibleItemId: "other-item", at: failedAt)

        XCTAssertEqual(log.lastFailure(itemId: "summary-item"),
                       .init(message: "Summary failed.", occurredAt: failedAt))
        XCTAssertNil(log.lastFailure(itemId: "other-item"))
    }

    func testOnlyUnattributedFailuresUseTheVisibleItem() {
        var log = ItemFailureLog()
        log.record("Visible item failed.", itemId: nil, visibleItemId: "visible-item")
        log.record("No item failed.", itemId: nil, visibleItemId: "")
        log.record("Explicitly no item.", itemId: "", visibleItemId: "other-item")

        XCTAssertEqual(log.lastFailure(itemId: "visible-item")?.message, "Visible item failed.")
        XCTAssertNil(log.lastFailure(itemId: "other-item"))
        XCTAssertNil(log.lastFailure(itemId: ""))
    }
}
