import XCTest
@testable import SessionKit

/// #4563: the one-time card that teaches the Watch's Return to App setting.
final class WatchReturnToAppTipPolicyTests: XCTestCase {
    private let paired = WatchPairingState(supported: true, activated: true, paired: true, appInstalled: true)

    private func decide(
        pairing: WatchPairingState? = nil,
        seen: Bool = false,
        hadMargin: Bool? = true,
        calm: Bool = true,
        supertonicDecided: Bool = true,
        noticeShown: Bool = false
    ) -> WatchReturnToAppTipPolicy.Decision {
        WatchReturnToAppTipPolicy.decide(
            pairing: pairing ?? paired, hasSeen: seen, hadMarginAtLaunch: hadMargin, calm: calm,
            supertonicDecided: supertonicDecided, noticeShownThisLaunch: noticeShown)
    }

    // MARK: Pairing

    func testPairingNeedsEveryFactBeforeItCountsAsAWatchWithTheApp() {
        XCTAssertTrue(paired.hasWatchApp)
        XCTAssertFalse(WatchPairingState(supported: false, activated: true, paired: true, appInstalled: true).hasWatchApp, "an iPad")
        XCTAssertFalse(WatchPairingState(supported: true, activated: false, paired: true, appInstalled: true).hasWatchApp, "not activated yet")
        XCTAssertFalse(WatchPairingState(supported: true, activated: true, paired: false, appInstalled: true).hasWatchApp, "no Watch")
        XCTAssertFalse(WatchPairingState(supported: true, activated: true, paired: true, appInstalled: false).hasWatchApp, "Watch without the app")
        XCTAssertFalse(WatchPairingState.none.hasWatchApp)
    }

    // MARK: The decision

    func testAPairedWatchWithTheAppAndAMarginAlreadySavedShowsTheCardWhenCalm() {
        XCTAssertEqual(decide(), .show)
    }

    func testOnceSeenItIsDoneWhateverElseHolds() {
        XCTAssertEqual(decide(seen: true), .done)
        XCTAssertEqual(decide(pairing: .none, seen: true), .done)
        XCTAssertEqual(decide(seen: true, hadMargin: false, calm: false), .done)
    }

    func testWithoutAWatchWithTheAppItWaitsAndNeverSettles() {
        // A Watch may be paired, or its app installed, later; nothing is recorded in the meantime.
        for pairing in [
            WatchPairingState.none,
            WatchPairingState(supported: true, activated: true, paired: false, appInstalled: false),
            WatchPairingState(supported: true, activated: true, paired: true, appInstalled: false),
            WatchPairingState(supported: true, activated: false, paired: true, appInstalled: true),
            WatchPairingState(supported: false, activated: true, paired: true, appInstalled: true),
        ] {
            XCTAssertEqual(decide(pairing: pairing), .wait, "\(pairing)")
        }
    }

    func testItNeverOpensInTheLaunchWhereTheFirstMarginIsMade() {
        // Library not loaded yet, or loaded with no Margin: the first run keeps its single question (#4679).
        XCTAssertEqual(decide(hadMargin: nil), .wait)
        XCTAssertEqual(decide(hadMargin: false), .wait)
        XCTAssertEqual(decide(hadMargin: true), .show)
    }

    func testItWaitsForAQuietMoment() {
        XCTAssertEqual(decide(calm: false), .wait)
        XCTAssertEqual(decide(calm: true), .show)
    }

    func testSupertonicDecidesFirstAndAtMostOneNoticeOpensPerLaunch() {
        XCTAssertEqual(decide(supertonicDecided: false), .wait)
        XCTAssertEqual(decide(noticeShown: true), .wait)
        XCTAssertEqual(decide(supertonicDecided: true, noticeShown: false), .show)
    }

    func testTheWatchAppInstalledWhileInTheBackgroundShowsOnlyOnceCalm() {
        let before = WatchPairingState(supported: true, activated: true, paired: true, appInstalled: false)
        XCTAssertEqual(decide(pairing: before), .wait)
        XCTAssertEqual(decide(pairing: paired, calm: false), .wait)
        XCTAssertEqual(decide(pairing: paired, calm: true), .show)
    }

    // MARK: Owed

    func testOwedMeansWatchWithAppAndAMarginAtLaunchAndNotSeen() {
        XCTAssertTrue(WatchReturnToAppTipPolicy.isOwed(pairing: paired, hasSeen: false, hadMarginAtLaunch: true))
        XCTAssertFalse(WatchReturnToAppTipPolicy.isOwed(pairing: paired, hasSeen: true, hadMarginAtLaunch: true))
        XCTAssertFalse(WatchReturnToAppTipPolicy.isOwed(pairing: paired, hasSeen: false, hadMarginAtLaunch: false))
        XCTAssertFalse(WatchReturnToAppTipPolicy.isOwed(pairing: paired, hasSeen: false, hadMarginAtLaunch: nil))
        XCTAssertFalse(WatchReturnToAppTipPolicy.isOwed(pairing: .none, hasSeen: false, hadMarginAtLaunch: true))
    }

    func testOwedAgreesWithTheDecisionWhenNothingElseBlocks() {
        for pairing in [paired, WatchPairingState.none] {
            for seen in [false, true] {
                for hadMargin in [nil, false, true] as [Bool?] {
                    let owed = WatchReturnToAppTipPolicy.isOwed(pairing: pairing, hasSeen: seen, hadMarginAtLaunch: hadMargin)
                    let decision = decide(pairing: pairing, seen: seen, hadMargin: hadMargin)
                    XCTAssertEqual(owed, decision == .show, "\(pairing) seen=\(seen) hadMargin=\(String(describing: hadMargin))")
                }
            }
        }
    }

    // MARK: The path

    func testTheStepsHoldTheOwnersPathInOrderOnePerStep() {
        let path = ["Settings", "General", "Return to Clock", "Spoken Margins", "Return to App"]
        let steps = WatchReturnToAppSteps.steps
        XCTAssertEqual(steps.count, path.count)
        for (step, name) in zip(steps, path) {
            XCTAssertTrue(step.contains(name), "\"\(step)\" should name \(name)")
        }
    }

    func testTheSeenKeyIsVersionedAndDistinctFromSupertonics() {
        XCTAssertEqual(WatchReturnToAppTipPolicy.seenKey, "watchReturnToAppTipSeenV1")
        XCTAssertNotEqual(WatchReturnToAppTipPolicy.seenKey, SupertonicDownloadNoticePolicy.seenKey)
    }
}
