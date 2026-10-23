import XCTest
import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// #2102: a reload read off the main thread may publish only while nothing newer has happened. The first version of
/// the Library and item refreshes had no such check in a test, so a slow read could overwrite a newer screen.
@MainActor
final class BackgroundRefreshGateTests: XCTestCase {
    private var priorTermsVersion: Any?
    private var priorTermsDate: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The lane wipes the app's data, and this class runs first, so no earlier test had accepted the terms. The
        // first playback then waited for the terms decision and started no session.
        priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDownWithError() throws {
        for (value, key) in [(priorTermsVersion, SpokenMarginsTerms.acceptanceVersionKey), (priorTermsDate, SpokenMarginsTerms.acceptanceDateKey)] {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try super.tearDownWithError()
    }

    func testANewerReloadOvertakesTheOneInFlight() {
        let gate = BackgroundRefreshGate()
        let first = gate.beginItem()
        XCTAssertTrue(gate.isCurrentItem(first))
        let second = gate.beginItem()
        XCTAssertFalse(gate.isCurrentItem(first), "the older read must not publish after a newer one began")
        XCTAssertTrue(gate.isCurrentItem(second))
    }

    func testAnotherAssignmentToTheSelectedItemOvertakesTheReload() {
        let gate = BackgroundRefreshGate()
        let reload = gate.beginItem()
        gate.selectionWasAssigned()
        XCTAssertFalse(gate.isCurrentItem(reload), "opening another item while a read is in flight drops that read")
    }

    func testPublishingTheReloadItselfDoesNotInvalidateIt() {
        let gate = BackgroundRefreshGate()
        let reload = gate.beginItem()
        gate.publishItem {
            gate.selectionWasAssigned() // the didSet fires for our own assignment
        }
        XCTAssertTrue(gate.isCurrentItem(reload))
    }

    func testTheLibraryAndItemGenerationsAreIndependent() {
        let gate = BackgroundRefreshGate()
        let item = gate.beginItem()
        let library = gate.beginLibrary()
        _ = gate.beginLibrary()
        XCTAssertFalse(gate.isCurrentLibrary(library))
        XCTAssertTrue(gate.isCurrentItem(item), "a newer Library read leaves the item reload alone")
    }

    func testAnItemOpenedWhileAPauseReloadsIsNotOverwrittenByTheOlderRead() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "First Item"
        model.importText = "One sentence only."
        model.importTextItem()
        let firstId = model.selectedItem.id
        model.pause() // reloads "First Item" off the main thread

        model.importTitle = "Second Item"
        model.importText = "Another sentence only."
        model.importTextItem()
        let secondId = model.selectedItem.id
        XCTAssertNotEqual(firstId, secondId)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.selectedItem.id, secondId, "the older read finished after the newer item opened and must be dropped")
        XCTAssertEqual(model.activePlaybackItemId, secondId)
    }

    func testASkipThatFinishesTheItemShowsTheFinishedSessionAtOnce() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Short Item"
        model.importText = "One sentence only."
        model.importTextItem()
        model.skipUnit = "section"
        model.skipForward()

        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        let shown = try XCTUnwrap(model.selectedItem.sessions.last)
        XCTAssertEqual(shown.completionPercent, 100, "Resume and Play read the finished session off the item at once, not after a background read")
    }
}
