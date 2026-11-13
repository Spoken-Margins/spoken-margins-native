import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4168: after ending a live session, Save as Notes left a screen to set up a new live session, and the listener had
/// to close it to reach the item. The likely cause, read from the code and not reproduced on a device: the save opened
/// the item itself, which swapped the root's screen (the Library, and the add sheet or Live row presenting the live
/// session screen) for the item's detail while that screen's cover was still up, and the cover, already let go of
/// its session, was left showing its setup card. The save now only writes; the screen closes first and opens the item
/// once it has gone (`LiveSessionFinish`). The first test fails on the old save, which opened the item itself.
@MainActor
final class LiveSessionSaveNavigationTests: XCTestCase {
    func testSavingLeavesTheScreenUnderTheLiveSessionScreenInPlace() async throws {
        let model = makeModel()
        let before = model.screen

        try await model.saveLiveSession(makeSession(title: "Shanti call"), transcript: nil, placed: [], recordingURL: nil)

        XCTAssertEqual(before, .home)
        XCTAssertEqual(model.screen, .home, "saving swapped the screen the live session screen is a cover over")
    }

    func testOpeningTheSavedSessionLandsOnItsItemDetail() async throws {
        let model = makeModel()
        let saved = try await model.saveLiveSession(makeSession(title: "Shanti call"), transcript: nil, placed: [], recordingURL: nil)

        await model.openSavedLiveSession(saved).value

        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.selectedItem.id, saved.itemId)
        XCTAssertEqual(model.selectedItem.title, "Shanti call")
        XCTAssertEqual(model.activeItemId, saved.itemId)
        XCTAssertEqual(model.statusMessage, "Saved Shanti call with 2 Margins.",
                       "the confirmation counts the session's Margins, not the transcript placements Save as Notes passes")
    }

    func testASecondTapWhileSavingDoesNotSaveAgain() {
        let finish = LiveSessionFinish()

        XCTAssertTrue(finish.beginSaving())
        XCTAssertFalse(finish.beginSaving(), "a second tap during Saving… started another save")
        finish.saved(Self.saved, dismiss: {}, open: { _ in })
        XCTAssertFalse(finish.beginSaving(), "a tap while the screen closes saved the session again")
    }

    func testAFailedSaveLeavesTheSessionToSaveAgain() {
        let finish = LiveSessionFinish()
        var opened: [Gate1AppModel.SavedLiveSession] = []

        XCTAssertTrue(finish.beginSaving())
        finish.saveFailed()
        finish.screenGone { opened.append($0) }

        XCTAssertEqual(finish.state, .open)
        XCTAssertTrue(opened.isEmpty, "a failed save opened an item")
        finish.screenAppeared()
        XCTAssertTrue(finish.beginSaving(), "after a failure the session can be saved again")
    }

    func testASavedSessionClosesTheScreenThenOpensItsItemOnce() {
        let finish = LiveSessionFinish()
        var dismissals = 0
        var opened: [Gate1AppModel.SavedLiveSession] = []
        XCTAssertTrue(finish.beginSaving())

        finish.saved(Self.saved, dismiss: { dismissals += 1 }, open: { opened.append($0) })

        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(opened.isEmpty, "the item opened while the live session screen was still up")
        XCTAssertFalse(finish.showsSetup, "a closing screen showed the setup card for a new session")
        finish.screenGone { opened.append($0) }
        finish.screenGone { opened.append($0) }
        XCTAssertEqual(opened, [Self.saved], "the item opens once, after the screen has gone")
    }

    func testASaveFinishingAfterTheScreenWentStillOpensItsItem() {
        let finish = LiveSessionFinish()
        var dismissals = 0
        var opened: [Gate1AppModel.SavedLiveSession] = []
        XCTAssertTrue(finish.beginSaving())
        finish.screenGone { opened.append($0) } // Back during Saving…

        finish.saved(Self.saved, dismiss: { dismissals += 1 }, open: { opened.append($0) })

        XCTAssertEqual(opened, [Self.saved])
        XCTAssertEqual(dismissals, 0)
    }

    func testAScreenBackFromItsOwnCoverWaitsToOpenTheItem() {
        let finish = LiveSessionFinish()
        var opened: [Gate1AppModel.SavedLiveSession] = []
        finish.screenGone { opened.append($0) } // the recording cover over it
        finish.screenAppeared()
        XCTAssertTrue(finish.beginSaving())

        finish.saved(Self.saved, dismiss: {}, open: { opened.append($0) })

        XCTAssertTrue(opened.isEmpty, "the item opened under a live session screen that was showing again")
    }

    func testDiscardingNeverShowsTheSetupCardOrOpensAnItem() {
        let finish = LiveSessionFinish()
        var opened: [Gate1AppModel.SavedLiveSession] = []

        finish.discarded()
        finish.screenGone { opened.append($0) }

        XCTAssertFalse(finish.showsSetup)
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - Fixtures

    private static let saved = Gate1AppModel.SavedLiveSession(itemId: "item-live-4168", title: "Shanti call", marginCount: 14)

    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        return model
    }

    /// An ended session the session store doesn't hold, with two typed Margins.
    private func makeSession(title: String) -> LiveSession {
        let start = Date(timeIntervalSinceNow: -600)
        return LiveSession(
            id: "live-4168-\(UUID().uuidString)", kind: .meeting, title: title, startedAt: start, endedAt: Date(),
            margins: [
                LiveSessionMargin(id: "m1-\(UUID().uuidString)", text: "Ask about the budget", markedAt: start.addingTimeInterval(60), sessionOffsetMs: 60_000),
                LiveSessionMargin(id: "m2-\(UUID().uuidString)", text: "Follow up next week", markedAt: start.addingTimeInterval(120), sessionOffsetMs: 120_000),
            ]
        )
    }
}
