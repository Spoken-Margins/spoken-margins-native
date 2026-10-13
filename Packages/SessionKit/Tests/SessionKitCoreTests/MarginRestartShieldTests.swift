import Foundation
import XCTest
@testable import SessionKit

/// #148: after Save & resume returns to the listening screen, a second tap at the same spot lands on Add a Margin.
/// Saving blocks the main thread and the screen then takes a while to draw, so the shield is anchored to the
/// listening screen appearing, not to the save returning.
final class MarginRestartShieldTests: XCTestCase {
    private let tap = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testAddAMarginWorksWhenNothingWasSaved() {
        XCTAssertTrue(MarginRestartShield().acceptsBegin(at: tap))
    }

    func testNoRecordingStartsWhileTheSaveIsUnderWay() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        XCTAssertFalse(shield.acceptsBegin(at: tap))
        XCTAssertFalse(shield.acceptsBegin(at: tap.addingTimeInterval(3)), "a slow save keeps the shield up however long it takes")
    }

    /// The owner's phone: the save returns at 0 s, the listening screen is drawn about 0.9 s later, and the queued
    /// second tap is delivered right after the draw. A timer that began when the save returned (0.7 s) had run out.
    func testASecondTapDeliveredAfterASlowDrawIsIgnored() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        shield.saveFinished(at: tap, stillRecording: false)
        XCTAssertFalse(shield.acceptsBegin(at: tap.addingTimeInterval(0.5)), "the screen hasn't appeared yet")
        shield.screenAppeared(at: tap.addingTimeInterval(0.9))
        XCTAssertFalse(shield.acceptsBegin(at: tap.addingTimeInterval(0.95)), "queued second tap, right after the draw")
        XCTAssertFalse(shield.acceptsBegin(at: tap.addingTimeInterval(0.9 + MarginRestartShield.window - 0.01)))
    }

    func testADeliberateTapAfterTheWindowStartsARecording() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        shield.saveFinished(at: tap, stillRecording: false)
        shield.screenAppeared(at: tap.addingTimeInterval(0.2))
        XCTAssertTrue(shield.acceptsBegin(at: tap.addingTimeInterval(0.2 + MarginRestartShield.window)))
        XCTAssertTrue(shield.acceptsBegin(at: tap.addingTimeInterval(30)))
    }

    func testOnlyTheFirstAppearanceAfterASaveStartsTheWindow() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        shield.saveFinished(at: tap, stillRecording: false)
        shield.screenAppeared(at: tap.addingTimeInterval(0.2))
        shield.screenAppeared(at: tap.addingTimeInterval(5))
        XCTAssertTrue(shield.acceptsBegin(at: tap.addingTimeInterval(1.5)), "a later appearance must not re-arm the shield")
    }

    func testAScreenThatAppearsWithoutASaveChangesNothing() {
        var shield = MarginRestartShield()
        shield.screenAppeared(at: tap)
        XCTAssertTrue(shield.acceptsBegin(at: tap))
    }

    func testAScreenThatNeverReportsDoesNotLeaveAddAMarginDead() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        shield.saveFinished(at: tap, stillRecording: false)
        XCTAssertFalse(shield.acceptsBegin(at: tap.addingTimeInterval(MarginRestartShield.longestWait - 0.1)))
        XCTAssertTrue(shield.acceptsBegin(at: tap.addingTimeInterval(MarginRestartShield.longestWait)))
    }

    func testASaveThatKeptRecordingOpensTheShieldAgain() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        shield.saveFinished(at: tap, stillRecording: true)
        XCTAssertTrue(shield.acceptsBegin(at: tap))
    }

    func testAScreenReportedBeforeTheSaveReturnsStartsTheWindowThere() {
        var shield = MarginRestartShield()
        shield.saveRequested()
        shield.screenAppeared(at: tap)
        shield.saveFinished(at: tap.addingTimeInterval(0.1), stillRecording: false)
        XCTAssertFalse(shield.acceptsBegin(at: tap.addingTimeInterval(0.5)))
        XCTAssertTrue(shield.acceptsBegin(at: tap.addingTimeInterval(MarginRestartShield.window)))
    }

    func testTheWindowIsOneSecond() {
        XCTAssertEqual(MarginRestartShield.window, 1.0)
    }
}
