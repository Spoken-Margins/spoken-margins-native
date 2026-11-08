import Foundation
import XCTest
@testable import SessionKit

/// #3633: the preparation's switch can throw, and `beginRecording` redoes it, so the start goes on. The reason the
/// switch threw (an error's domain and code) used to be dropped; it now reaches the claim and the diagnostics.
/// Runs on Linux too: `RecordingSessionPreparation` has no AVFoundation in it.
final class RecordingSessionPreparationFailureTests: XCTestCase {
    private struct Context: Sendable, Equatable { var route: String }

    func testAFailedSwitchHandsItsReasonToTheClaim() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep.failure")
        let started = expectation(description: "start runs")
        preparation.prepare(
            readContext: { Context(route: "AirPlay") },
            applyReportingFailure: { _ in .init(applied: false, failure: "NSOSStatusErrorDomain#561017449") },
            then: { started.fulfill() }
        )
        wait(for: [started], timeout: 5)
        let claim = preparation.claim()
        XCTAssertEqual(claim?.applied, false)
        XCTAssertEqual(claim?.failure, "NSOSStatusErrorDomain#561017449")
        XCTAssertEqual(claim?.context, Context(route: "AirPlay"))
    }

    func testAFailureAfterTheCategoryChangedStillLetsAbandonGoOfTheSession() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep.failure")
        let started = expectation(description: "start runs")
        preparation.prepare(
            readContext: { Context(route: "A2DP") },
            applyReportingFailure: { _ in .init(applied: true, failure: "NSOSStatusErrorDomain#561015905") },
            then: { started.fulfill() }
        )
        wait(for: [started], timeout: 5)
        XCTAssertTrue(preparation.abandon(), "the category was switched before setActive threw: abandoning must let go")
    }

    func testASwitchThatWorkedOrReportsOnlyABoolCarriesNoReason() {
        let preparation = RecordingSessionPreparation<Context>(label: "test.prep.failure")
        let started = expectation(description: "start runs")
        preparation.prepare(readContext: { Context(route: "A2DP") }, apply: { _ in false }, then: { started.fulfill() })
        wait(for: [started], timeout: 5)
        XCTAssertNil(preparation.claim()?.failure)
    }
}
