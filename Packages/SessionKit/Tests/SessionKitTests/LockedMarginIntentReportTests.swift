import XCTest
@testable import SessionKit

/// The locked-phone spike (#3086) reads its pass or fail from this report, so each outcome must be told apart.
final class LockedMarginIntentReportTests: XCTestCase {
    private func report(_ action: LockedMarginIntentReport.Action, was: Bool, now: Bool,
                        failure: String? = nil) -> LockedMarginIntentReport {
        LockedMarginIntentReport(
            action: action, appState: "background", protectedDataAvailable: false,
            liveActivitiesBefore: 1, liveActivitiesAfter: 1, audioCategoryBefore: "AVAudioSessionCategoryPlayback",
            microphonePermission: "granted", wasRecording: was, isRecording: now, failure: failure
        )
    }

    func testEveryBeginAndFinishCaseHasItsOwnOutcome() {
        let table: [(LockedMarginIntentReport.Action, Bool, Bool, LockedMarginIntentReport.Outcome, Bool)] = [
            (.begin, false, true, .started, true),
            (.begin, false, false, .notStarted, false),
            (.begin, true, true, .alreadyRecording, true),
            (.finish, true, false, .finished, true),
            (.finish, true, true, .notFinished, false),
            (.finish, false, false, .nothingToFinish, true),
        ]
        for (action, was, now, outcome, succeeded) in table {
            let report = report(action, was: was, now: now)
            XCTAssertEqual(report.outcome, outcome, "\(action) was=\(was) now=\(now)")
            XCTAssertEqual(report.succeeded, succeeded, "\(action) was=\(was) now=\(now)")
        }
    }

    func testFieldsCarryTheLockHintLiveActivityAndRawFailure() {
        let failed = report(.begin, was: false, now: false,
                            failure: "Compact control failed: CMSUtility_IsAllowedToStartRecording")
        XCTAssertEqual(failed.fields["outcome"], "not_started")
        XCTAssertEqual(failed.fields["protectedData"], "unavailable_maybe_locked")
        XCTAssertEqual(failed.fields["liveActivitiesBefore"], "1")
        XCTAssertEqual(failed.fields["appState"], "background")
        XCTAssertEqual(failed.fields["failure"], "Compact control failed: CMSUtility_IsAllowedToStartRecording")
        XCTAssertTrue(failed.summary.contains("outcome=not_started"))
        XCTAssertTrue(failed.summary.contains("protectedData=unavailable_maybe_locked"))
    }

    func testNoFailureFieldWhenNothingFailed() {
        XCTAssertNil(report(.begin, was: false, now: true).fields["failure"])
        XCTAssertNil(report(.begin, was: false, now: true, failure: "").fields["failure"])
    }
}
