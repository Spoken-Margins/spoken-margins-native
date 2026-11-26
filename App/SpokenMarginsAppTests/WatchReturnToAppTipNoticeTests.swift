import SessionKit
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #4563: the one-time card that teaches the Watch's Return to App setting. The rule itself is
/// `WatchReturnToAppTipPolicyTests` in SessionKit; this is the state it drives: when the flag is written, the
/// relaunch behaviour, the Settings route and the scripted-UI switch.
@MainActor
final class WatchReturnToAppTipNoticeTests: XCTestCase {
    private static let pairedWithApp = WatchPairingState(supported: true, activated: true, paired: true, appInstalled: true)

    private func defaults() -> UserDefaults {
        let name = "WatchReturnToAppTipNoticeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    /// A notice that has everything it needs except the thing a case changes.
    private func notice(
        _ store: UserDefaults,
        pairing: WatchPairingState = WatchReturnToAppTipNoticeTests.pairedWithApp,
        hadMargin: Bool? = true,
        forcesNoWatch: Bool = false
    ) -> WatchReturnToAppTipNotice {
        let notice = WatchReturnToAppTipNotice(defaults: store, forcesNoWatch: forcesNoWatch)
        notice.updatePairing(pairing)
        if let hadMargin { notice.noteLibraryLoaded(hadMargin: hadMargin) }
        return notice
    }

    private func offer(_ notice: WatchReturnToAppTipNotice, calm: Bool = true, supertonicShown: Bool = false) {
        notice.presentIfNeeded(calm: calm, supertonicDecided: true, supertonicShownThisLaunch: supertonicShown)
    }

    func testAPairedWatchAndAMarginAtLaunchOpensTheCardAtAQuietMoment() {
        let notice = notice(defaults())
        offer(notice)
        XCTAssertTrue(notice.isPresented)
    }

    func testTheCardIsSeenOnlyOnceItAppearsAndNeverComesBack() {
        let store = defaults()
        let first = notice(store)
        offer(first)
        XCTAssertNil(store.object(forKey: WatchReturnToAppTipPolicy.seenKey), "asked for is not seen")
        first.cardAppeared()
        XCTAssertTrue(store.bool(forKey: WatchReturnToAppTipPolicy.seenKey))

        let nextLaunch = notice(store)
        offer(nextLaunch)
        XCTAssertFalse(nextLaunch.isPresented)
    }

    func testACardAskedForButNeverDrawnComesBackNextLaunch() {
        let store = defaults()
        let first = notice(store)
        offer(first)
        XCTAssertTrue(first.isPresented) // killed before `cardAppeared()`

        let nextLaunch = notice(store)
        offer(nextLaunch)
        XCTAssertTrue(nextLaunch.isPresented, "a dropped presentation can't lose the card")
    }

    func testNoMarginAtLaunchOrNothingLoadedYetNeverOpensIt() {
        let none = notice(defaults(), hadMargin: false)
        offer(none)
        XCTAssertFalse(none.isPresented)
        let notLoaded = notice(defaults(), hadMargin: nil)
        offer(notLoaded)
        XCTAssertFalse(notLoaded.isPresented)
    }

    func testOnlyTheFirstLibraryLoadOfALaunchCounts() {
        let notice = notice(defaults(), hadMargin: false)
        notice.noteLibraryLoaded(hadMargin: true) // a Margin made later this launch
        XCTAssertEqual(notice.hadMarginAtLaunch, false)
        offer(notice)
        XCTAssertFalse(notice.isPresented, "the card never sits inside the first run")
    }

    func testAFlagWrittenByAnAutomaticCardSurvivesASettingsOpenAfterwards() {
        let store = defaults()
        let notice = notice(store)
        offer(notice)
        notice.cardAppeared()
        notice.close()
        notice.openFromSettings()
        notice.cardAppeared()
        XCTAssertTrue(store.bool(forKey: WatchReturnToAppTipPolicy.seenKey))
    }

    func testSettingsOpensItWithoutWritingTheFlag() {
        let store = defaults()
        let notice = notice(store, hadMargin: false)
        notice.openFromSettings()
        XCTAssertTrue(notice.isPresented)
        notice.cardAppeared() // the card's onAppear
        XCTAssertNil(store.object(forKey: WatchReturnToAppTipPolicy.seenKey))
        notice.close()
        XCTAssertFalse(notice.isPresented)
    }

    func testScriptedUIRunsNeverMeetTheCard() {
        let notice = notice(defaults(), forcesNoWatch: true)
        offer(notice)
        XCTAssertFalse(notice.isPresented)
        XCTAssertFalse(notice.pairing.hasWatchApp, "the Settings row stays hidden too")
        XCTAssertFalse(notice.isOwed)
    }

    func testAnotherNoticeThisLaunchOrABusyScreenKeepsItWaiting() {
        let afterSupertonic = notice(defaults())
        offer(afterSupertonic, supertonicShown: true)
        XCTAssertFalse(afterSupertonic.isPresented)

        let busy = notice(defaults())
        offer(busy, calm: false)
        XCTAssertFalse(busy.isPresented)
        XCTAssertTrue(busy.isOwed, "still owed, so the root keeps asking")
        offer(busy, calm: true)
        XCTAssertTrue(busy.isPresented)
    }

    func testNoWatchOrAWatchWithoutTheAppNeverOpensIt() {
        for pairing in [
            WatchPairingState.none,
            WatchPairingState(supported: true, activated: true, paired: true, appInstalled: false),
            WatchPairingState(supported: false, activated: true, paired: true, appInstalled: true), // an iPad
        ] {
            let notice = notice(defaults(), pairing: pairing)
            offer(notice)
            XCTAssertFalse(notice.isPresented, "\(pairing)")
        }
    }

    func testAWatchPairedLaterOpensItOnceOwed() {
        let notice = notice(defaults(), pairing: .none)
        offer(notice)
        XCTAssertFalse(notice.isPresented)
        notice.updatePairing(Self.pairedWithApp)
        offer(notice)
        XCTAssertTrue(notice.isPresented)
    }

    func testTheSupertonicNoticeReportsItsDecisionToTheWatchCard() {
        let store = defaults()
        let supertonic = SupertonicDownloadNotice(defaults: store, modelInstalled: { false })
        XCTAssertFalse(supertonic.decidedThisLaunch)
        supertonic.presentIfNeeded(savedVoiceIsSupertonic: false, anotherSheetShowing: false)
        XCTAssertTrue(supertonic.decidedThisLaunch)
        XCTAssertFalse(supertonic.shownThisLaunch)

        let showing = SupertonicDownloadNotice(defaults: defaults(), modelInstalled: { false })
        showing.presentIfNeeded(savedVoiceIsSupertonic: true, anotherSheetShowing: false)
        XCTAssertTrue(showing.shownThisLaunch)
    }

    func testRootHasPresentationIsFalseWithNothingOverIt() {
        XCTAssertFalse(ShareFilePresenter.rootHasPresentation(from: nil))
        let root = UIViewController()
        XCTAssertFalse(ShareFilePresenter.rootHasPresentation(from: root))

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.present(UIViewController(), animated: false)
        XCTAssertTrue(ShareFilePresenter.rootHasPresentation(from: root), "a sheet over the root counts")
        window.isHidden = true
    }
}
