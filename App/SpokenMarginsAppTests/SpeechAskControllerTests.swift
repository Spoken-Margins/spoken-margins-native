import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #4715 / #5016: the controller that carries `SpeechRecognitionAsk`'s decisions out, on a real temporary UserDefaults
/// suite with iOS's answer and iOS's prompt injected. Nothing here raises the real prompt.
@MainActor
final class SpeechAskControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var iosAnswer = SpeechRecognitionAccessState.notDetermined
    private var promptsRaised = 0

    override func setUp() {
        super.setUp()
        suiteName = "SpeechAskControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        iosAnswer = .notDetermined
        promptsRaised = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> SpeechAskController {
        SpeechAskController(
            defaults: defaults,
            access: { [unowned self] in iosAnswer },
            isSuppressed: { false },
            askSystem: { [unowned self] in await MainActor.run { promptsRaised += 1 } })
    }

    func testCardShowsAfterASpokenSaveAndNotAfterAWrittenOne() {
        let written = makeController()
        written.spokenMarginSaved(isWritten: true)
        XCTAssertFalse(written.isCardShowing(slotIsFree: true))
        XCTAssertFalse(written.isOutstanding)

        let spoken = makeController()
        spoken.spokenMarginSaved(isWritten: false)
        XCTAssertTrue(spoken.isCardShowing(slotIsFree: true))
        XCTAssertTrue(spoken.isOutstanding)
    }

    /// One slot rule: a friend's card or a footnote card (the slot is not free) keeps the card away, and it returns after.
    func testCardWaitsWhileTheSlotIsHeld() {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        let friends = NowPinnedSlot(friendsMarginCardShowing: true, footnoteCardShowing: false, recordingIsLocked: false)
        let footnote = NowPinnedSlot(friendsMarginCardShowing: false, footnoteCardShowing: true, recordingIsLocked: false)
        let locked = NowPinnedSlot(friendsMarginCardShowing: false, footnoteCardShowing: false, recordingIsLocked: true)
        let free = NowPinnedSlot(friendsMarginCardShowing: false, footnoteCardShowing: false, recordingIsLocked: false)
        for held in [friends, footnote, locked] {
            XCTAssertFalse(controller.isCardShowing(slotIsFree: held.isFreeForSpeechAsk))
        }
        XCTAssertTrue(controller.isCardShowing(slotIsFree: free.isFreeForSpeechAsk))
        XCTAssertFalse(controller.isCardShowing(on: .margins, slotIsFree: true), "it shows only on its own surface")
    }

    /// Leaving the surface a re-ask was drawn on, unanswered, puts the card back on Now; an answer does not.
    func testLeavingTheReaskSurfaceWithoutAnsweringReturnsTheCardToNow() {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        controller.getTranscript(on: .detail, model: nil)
        XCTAssertFalse(controller.isCardShowing(on: .now, slotIsFree: true))
        controller.surfaceLeft(.detail)
        XCTAssertTrue(controller.isCardShowing(on: .now, slotIsFree: true))

        controller.getTranscript(on: .margins, model: nil)
        controller.notNow()
        controller.surfaceLeft(.margins)
        XCTAssertNil(controller.cardSurface)
    }

    func testUnansweredCardSurvivesARelaunchWhileAMarginWaits() {
        let first = makeController()
        first.spokenMarginSaved(isWritten: false)
        first.marginIsWaiting(marginIdentity: "s1::m1")
        let relaunched = makeController()
        XCTAssertTrue(relaunched.isCardShowing(slotIsFree: true))
        XCTAssertTrue(relaunched.isOutstanding)
        XCTAssertTrue(relaunched.isWaiting(marginIdentity: "s1::m1"))
    }

    func testNotNowIsOutstandingNoMoreAndTheListStaysUntilIOSDecides() {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        controller.marginIsWaiting(marginIdentity: "s1::m1")
        controller.notNow()
        XCTAssertFalse(controller.isCardShowing(slotIsFree: true))
        XCTAssertFalse(controller.isOutstanding)
        XCTAssertTrue(controller.isWaiting(marginIdentity: "s1::m1"))
    }

    func testYesAsksIOSOnceAndAllowedClearsTheWaitingList() async {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        controller.marginIsWaiting(marginIdentity: "s1::m1")
        iosAnswer = .authorized
        await controller.yes(model: nil).value
        XCTAssertEqual(promptsRaised, 1)
        XCTAssertFalse(controller.isWaiting(marginIdentity: "s1::m1"))
        XCTAssertNil(defaults.stringArray(forKey: SpeechAskWaitingList.storageKey))
        XCTAssertEqual(defaults.string(forKey: SpeechRecognitionAsk.storageKey), "yes")
    }

    func testDeniedClearsTheWaitingListSoTheOldWordingApplies() async {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        controller.marginIsWaiting(marginIdentity: "s1::m1")
        iosAnswer = .denied
        await controller.yes(model: nil).value
        XCTAssertNil(defaults.stringArray(forKey: SpeechAskWaitingList.storageKey))
        XCTAssertFalse(controller.isOutstanding)
    }

    func testAnAnswerGivenInSettingsIsSettledWhenTheNowPaneReconciles() {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        controller.marginIsWaiting(marginIdentity: "s1::m1")
        iosAnswer = .denied
        controller.reconcile(model: nil)
        XCTAssertFalse(controller.isCardShowing(slotIsFree: true))
        XCTAssertNil(defaults.stringArray(forKey: SpeechAskWaitingList.storageKey))
    }

    /// The re-ask after Not now shows once per launch; Get Transcript is a direct request and shows it anyway.
    func testReAskIsOncePerLaunchButGetTranscriptAlwaysShowsTheCard() {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        controller.notNow()
        controller.reachedForText(on: .margins)
        XCTAssertTrue(controller.isCardShowing(on: .margins, slotIsFree: true))
        controller.notNow()
        controller.reachedForText(on: .margins)
        XCTAssertFalse(controller.isCardShowing(on: .margins, slotIsFree: true), "the second re-ask this launch is held")
        controller.getTranscript(on: .detail, model: nil)
        XCTAssertTrue(controller.isCardShowing(on: .detail, slotIsFree: true))
    }

    /// Closed while iOS's prompt was up after Yes: the Yes is dropped, the card returns, iOS stays closed, and Get Transcript
    /// reaches the card instead of doing nothing.
    func testAYesIOSNeverAnsweredComesBackAsTheCardAndNeverAsksMidSave() {
        defaults.set("yes", forKey: SpeechRecognitionAsk.storageKey)
        defaults.set(["s1::m1"], forKey: SpeechAskWaitingList.storageKey)
        let controller = makeController()
        XCTAssertNil(defaults.string(forKey: SpeechRecognitionAsk.storageKey))
        XCTAssertTrue(controller.isCardShowing(slotIsFree: true))
        XCTAssertFalse(controller.ask.mayAskSystem(access: .notDetermined))
        controller.getTranscript(on: .detail, model: nil)
        XCTAssertTrue(controller.isCardShowing(on: .detail, slotIsFree: true))
    }

    /// Yes said in this launch but iOS still undecided: Get Transcript asks iOS again.
    func testGetTranscriptAfterYesAsksIOSAgain() async {
        let controller = makeController()
        controller.spokenMarginSaved(isWritten: false)
        await controller.yes(model: nil).value
        XCTAssertEqual(promptsRaised, 1)
        controller.getTranscript(on: .detail, model: nil)
        // The ask is a task on the main actor; wait for the count itself, never the clock.
        for _ in 0..<1000 where promptsRaised == 1 { await Task.yield() }
        XCTAssertEqual(promptsRaised, 2)
    }

    /// Rows read the stored list off the main actor: a listed Margin waits while iOS is undecided, and not once it decides.
    func testMarginIdentitiesAreReadOffTheMainActor() {
        defaults.set(["s1::m1"], forKey: SpeechAskWaitingList.storageKey)
        XCTAssertTrue(SpeechAskController.marginIsWaitingForAnswer("s1::m1", defaults: defaults, access: .notDetermined))
        XCTAssertFalse(SpeechAskController.marginIsWaitingForAnswer("s1::m1", defaults: defaults, access: .authorized))
        XCTAssertFalse(SpeechAskController.marginIsWaitingForAnswer("s1::m1", defaults: defaults, access: .denied))
        XCTAssertFalse(SpeechAskController.marginIsWaitingForAnswer("s1::other", defaults: defaults, access: .notDetermined))
        XCTAssertFalse(SpeechAskController.marginIsWaitingForAnswer("", defaults: defaults, access: .notDetermined))
    }
}
