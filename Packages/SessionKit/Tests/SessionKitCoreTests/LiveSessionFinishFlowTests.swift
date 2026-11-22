import XCTest
@testable import SessionKit

/// #4168: after ending a live session, Save as Notes left a screen to set up a new live session, and the listener had
/// to close it to reach the item. The screen now closes first and opens the item once it has gone. These tests moved
/// from the app-hosted suite (#318); the app's `LiveSessionSaveNavigationTests` still checks its wrapper.
final class LiveSessionFinishFlowTests: XCTestCase {
    private struct Saved: Equatable { let itemId: String }
    private static let saved = Saved(itemId: "item-live-4168")

    func testASecondTapWhileSavingDoesNotSaveAgain() {
        var finish = LiveSessionFinishFlow<Saved>()

        XCTAssertTrue(finish.beginSaving())
        XCTAssertFalse(finish.beginSaving(), "a second tap during Saving… started another save")
        finish.saved(Self.saved, dismiss: {}, open: { _ in })
        XCTAssertFalse(finish.beginSaving(), "a tap while the screen closes saved the session again")
    }

    func testAFailedSaveLeavesTheSessionToSaveAgain() {
        var finish = LiveSessionFinishFlow<Saved>()
        var opened: [Saved] = []

        XCTAssertTrue(finish.beginSaving())
        finish.saveFailed()
        finish.screenGone { opened.append($0) }

        XCTAssertEqual(finish.state, .open)
        XCTAssertTrue(opened.isEmpty, "a failed save opened an item")
        finish.screenAppeared()
        XCTAssertTrue(finish.beginSaving(), "after a failure the session can be saved again")
    }

    func testASavedSessionClosesTheScreenThenOpensItsItemOnce() {
        var finish = LiveSessionFinishFlow<Saved>()
        var dismissals = 0
        var opened: [Saved] = []
        XCTAssertTrue(finish.beginSaving())

        finish.saved(Self.saved, dismiss: { dismissals += 1 }, open: { opened.append($0) })

        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(opened.isEmpty, "the item opened while the live session screen was still up")
        XCTAssertFalse(finish.showsSetup, "a closing screen showed the setup card for a new session")
        finish.screenGone { opened.append($0) }
        finish.screenGone { opened.append($0) }
        XCTAssertEqual(opened, [Self.saved], "the item opens once, after the screen has gone")
        XCTAssertEqual(finish.state, .closed)
    }

    func testASaveFinishingAfterTheScreenWentStillOpensItsItem() {
        var finish = LiveSessionFinishFlow<Saved>()
        var dismissals = 0
        var opened: [Saved] = []
        XCTAssertTrue(finish.beginSaving())
        finish.screenGone { opened.append($0) } // Back during Saving…

        finish.saved(Self.saved, dismiss: { dismissals += 1 }, open: { opened.append($0) })

        XCTAssertEqual(opened, [Self.saved])
        XCTAssertEqual(dismissals, 0)
    }

    func testAScreenBackFromItsOwnCoverWaitsToOpenTheItem() {
        var finish = LiveSessionFinishFlow<Saved>()
        var opened: [Saved] = []
        finish.screenGone { opened.append($0) } // the recording cover over it
        finish.screenAppeared()
        XCTAssertTrue(finish.beginSaving())

        finish.saved(Self.saved, dismiss: {}, open: { opened.append($0) })

        XCTAssertTrue(opened.isEmpty, "the item opened under a live session screen that was showing again")
    }

    func testDiscardingNeverShowsTheSetupCardOrOpensAnItem() {
        var finish = LiveSessionFinishFlow<Saved>()
        var opened: [Saved] = []

        finish.discarded()
        finish.screenGone { opened.append($0) }

        XCTAssertFalse(finish.showsSetup)
        XCTAssertTrue(opened.isEmpty)
    }

    func testAFreshScreenShowsTheSetupCardAndIsNotSaving() {
        let finish = LiveSessionFinishFlow<Saved>()
        XCTAssertTrue(finish.showsSetup)
        XCTAssertFalse(finish.isSaving)
        XCTAssertEqual(finish.state, .open)
    }

    func testASaveCannotFinishTwiceOrAfterADiscard() {
        var finish = LiveSessionFinishFlow<Saved>()
        var dismissals = 0
        XCTAssertTrue(finish.beginSaving())
        finish.saved(Self.saved, dismiss: { dismissals += 1 }, open: { _ in })
        finish.saved(Saved(itemId: "second"), dismiss: { dismissals += 1 }, open: { _ in })
        XCTAssertEqual(dismissals, 1, "a second finished save closed the screen again")
        XCTAssertEqual(finish.state, .saved(Self.saved), "a second finished save replaced the first")

        var discarded = LiveSessionFinishFlow<Saved>()
        discarded.discarded()
        var opened: [Saved] = []
        discarded.saved(Self.saved, dismiss: { dismissals += 1 }, open: { opened.append($0) })
        XCTAssertEqual(discarded.state, .closed)
        XCTAssertTrue(opened.isEmpty)
    }
}
