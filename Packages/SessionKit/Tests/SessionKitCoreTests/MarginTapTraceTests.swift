import SessionKit
import XCTest

/// #4447: the owner's export had no line for a tap on a Margin in the Margins tab, so a tap that did nothing left no
/// trace. Every tap now logs one `margin.tap` with an outcome, and every way it can end unplayed has its own reason.
final class MarginTapTraceTests: XCTestCase {
    func testEachOutcomeAndItsFields() {
        let table: [(MarginTapOutcome, [String: String])] = [
            (.started, ["origin": "own", "outcome": "started"]),
            (.waiting(.readingNotReady), ["origin": "own", "outcome": "waiting", "reason": "reading_not_ready"]),
            (.refused(.noPosition), ["origin": "own", "outcome": "refused", "reason": "no_position"]),
            (.dropped(.leftScreen), ["origin": "own", "outcome": "dropped", "reason": "left_screen"]),
        ]
        for (outcome, fields) in table {
            XCTAssertEqual(outcome.diagnosticFields(origin: .own), fields)
        }
        XCTAssertEqual(MarginTapOutcome.started.diagnosticFields(origin: .shared)["origin"], "shared")
    }

    func testTheEventCarriesNothingThatNamesTheMarginOrTheListener() {
        for reason in MarginTapReason.allCases {
            for outcome in [MarginTapOutcome.refused(reason), .dropped(reason), .waiting(reason)] {
                XCTAssertEqual(Set(outcome.diagnosticFields(origin: .shared).keys), ["origin", "outcome", "reason"])
            }
        }
    }

    func testEveryReasonHasADistinctPlainDiagnosticsName() {
        let names = MarginTapReason.allCases.map(\.rawValue)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertEqual(name, name.lowercased())
            XCTAssertFalse(name.contains(" "))
            XCTAssertFalse(name.isEmpty)
        }
    }

    private func drop(
        cancelled: Bool = false, current: Bool = true, sameScreen: Bool = true, sameLanding: Bool = true, recording: Bool = false
    ) -> MarginTapReason? {
        MarginTapLateResult.dropReason(
            cancelled: cancelled, openIsCurrent: current, stillOnTheScreenTheTapCameFrom: sameScreen,
            playbackIsWhatTheTapSaw: sameLanding, recordingLocked: recording)
    }

    func testALateResultPlaysOnlyWhenNothingMoved() {
        XCTAssertNil(drop())
    }

    func testEachWayThingsMoveOnHasItsOwnReason() {
        XCTAssertEqual(drop(cancelled: true), .cancelled)
        XCTAssertEqual(drop(current: false), .openSuperseded)
        XCTAssertEqual(drop(sameScreen: false), .leftScreen)
        XCTAssertEqual(drop(sameLanding: false), .playbackMoved)
        XCTAssertEqual(drop(recording: true), .recordingInProgress)
    }

    func testWhenSeveralThingsMovedTheEarliestCheckNamesIt() {
        XCTAssertEqual(drop(cancelled: true, current: false, sameScreen: false, sameLanding: false, recording: true), .openSuperseded,
                       "a newer open cancels the tap's task too, so the open is named, not the cancel")
        XCTAssertEqual(drop(cancelled: true, sameScreen: false, sameLanding: false, recording: true), .cancelled)
        XCTAssertEqual(drop(current: false, sameScreen: false, sameLanding: false, recording: true), .openSuperseded)
        XCTAssertEqual(drop(sameScreen: false, sameLanding: false, recording: true), .leftScreen)
        XCTAssertEqual(drop(sameLanding: false, recording: true), .playbackMoved)
    }
}
