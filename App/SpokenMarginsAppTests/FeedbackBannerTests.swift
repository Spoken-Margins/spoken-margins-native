import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #310: an error banner vanished after 6 seconds and the failure couldn't be read again.
@MainActor
final class FeedbackBannerTests: XCTestCase {
    func testAFailureOnAnItemStaysReadableOnThatItemAfterItsBannerCloses() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.openItem(id: "item-pill")
        XCTAssertEqual(model.screen, .item)

        // Reports a failure: the item isn't in Recently Deleted.
        model.permanentlyDeleteItem(id: "item-pill")
        let message = "Move the item to Recently Deleted before deleting it permanently."
        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill")?.message, message)

        model.dismissFeedback()
        model.openHome()
        model.openItem(id: "item-pill")
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.itemFailures.lastFailure(itemId: "item-pill")?.message, message)

        model.clearLastFailure(itemId: "item-pill")
        XCTAssertNil(model.itemFailures.lastFailure(itemId: "item-pill"))
    }

    func testAFailureAwayFromAnItemIsNotPinnedToOne() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.openItem(id: "item-pill")
        model.openHome()
        XCTAssertEqual(model.screen, .home)

        model.permanentlyDeleteItem(id: "item-pill")

        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertNil(model.itemFailures.lastFailure(itemId: "item-pill"))
    }

    func testAConfirmationDoesNotCoverAnErrorThatOffersRetry() {
        let retryable = UserFeedbackEvent(kind: .error, message: "The request timed out.", retry: {})
        let plain = UserFeedbackEvent(kind: .error, message: "Clipboard does not contain text.")
        let confirmation = UserFeedbackEvent(kind: .success, message: "Copied.")

        XCTAssertFalse(retryable.mayBeReplaced(by: confirmation))
        XCTAssertTrue(retryable.mayBeReplaced(by: plain))
        XCTAssertTrue(plain.mayBeReplaced(by: confirmation))
    }
}
