import Foundation
import XCTest
@testable import SessionKit

/// The podcast Now view lists the Margins nearest the playhead and counts down to the next one (#447).
final class PlaybackNowMarginsTests: XCTestCase {
    private typealias Now = PlaybackNowMargins
    private typealias Margin = PlaybackNowMargins.Margin

    private func margin(_ id: String, _ position: Double, _ origin: Now.Origin = .own, approximate: Bool = false) -> Margin {
        Margin(id: id, position: position, origin: origin, isApproximate: approximate)
    }

    // MARK: Which Margins

    func testNoMarginsListsNothing() {
        XCTAssertEqual(Now.rows(playhead: 120, margins: []), [])
    }

    func testAllMarginsBehindThePlayheadHaveNoCountdown() {
        let rows = Now.rows(playhead: 600, margins: [margin("a", 100), margin("b", 300)])
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
        XCTAssertEqual(rows.map(\.countdown), [nil, nil])
    }

    func testOnlyTheFirstMarginAheadCountsDown() {
        let rows = Now.rows(playhead: 100, margins: [margin("a", 40), margin("b", 180), margin("c", 400)])
        XCTAssertEqual(rows.map(\.id), ["a", "b", "c"], "listening order, behind then ahead")
        XCTAssertEqual(rows.map(\.countdown), [nil, "in 1:20", nil])
    }

    func testListsTheNearestFourInListeningOrder() {
        let margins = [margin("a", 10), margin("b", 200), margin("c", 290), margin("d", 310), margin("e", 330), margin("f", 900)]
        let rows = Now.rows(playhead: 300, margins: margins)
        XCTAssertEqual(rows.map(\.id), ["b", "c", "d", "e"])
        XCTAssertEqual(rows.map(\.countdown), [nil, nil, "in 0:10", nil])
    }

    func testTheNextMarginAheadIsListedEvenWhenFourSitCloserBehind() {
        let margins = [margin("a", 296), margin("b", 297), margin("c", 298), margin("d", 299), margin("far", 1_500)]
        let rows = Now.rows(playhead: 300, margins: margins)
        XCTAssertEqual(rows.map(\.id), ["b", "c", "d", "far"], "the countdown never disappears behind a crowd")
        XCTAssertEqual(rows.last?.countdown, "in 20:00")
    }

    func testTwoMarginsAtTheSamePositionShareTheCountdownAndSortById() {
        let rows = Now.rows(playhead: 0, margins: [margin("z", 75, .shared), margin("m", 75, .own)])
        XCTAssertEqual(rows.map(\.id), ["m", "z"])
        XCTAssertEqual(rows.map(\.countdown), ["in 1:15", "in 1:15"])
    }

    func testAMarginExactlyAtThePlayheadCountsAsBehind() {
        let rows = Now.rows(playhead: 90, margins: [margin("here", 90), margin("next", 150)])
        XCTAssertEqual(rows.map(\.countdown), [nil, "in 1:00"])
    }

    func testEquallyCloseMarginsPreferTheOneAhead() {
        let margins = [margin("next", 101), margin("behind", 90), margin("ahead", 110)]
        XCTAssertEqual(Now.rows(playhead: 100, margins: margins, limit: 2).map(\.id), ["next", "ahead"])
    }

    func testOwnAndSharedMarginsKeepTheirOrigin() {
        let rows = Now.rows(playhead: 0, margins: [margin("mine", 10, .own), margin("theirs", 20, .shared)])
        XCTAssertEqual(rows.map(\.origin), [.own, .shared])
    }

    func testPositionsThatAreNotNumbersAreLeftOut() {
        let rows = Now.rows(playhead: 10, margins: [margin("nan", .nan), margin("inf", .infinity), margin("ok", 20)])
        XCTAssertEqual(rows.map(\.id), ["ok"])
        XCTAssertEqual(Now.rows(playhead: .nan, margins: [margin("ok", 20)]), [])
    }

    func testALimitOfZeroListsNothing() {
        XCTAssertEqual(Now.rows(playhead: 0, margins: [margin("a", 5)], limit: 0), [])
    }

    func testInputOrderDoesNotChangeTheResult() {
        let margins = [margin("c", 30), margin("a", 10), margin("b", 20)]
        XCTAssertEqual(Now.rows(playhead: 15, margins: margins), Now.rows(playhead: 15, margins: Array(margins.reversed())))
    }

    // MARK: Countdown text

    func testCountdownFormatsMinutesAndSeconds() {
        XCTAssertEqual(Now.countdownText(secondsAhead: 80, isApproximate: false), "in 1:20")
        XCTAssertEqual(Now.countdownText(secondsAhead: 9, isApproximate: false), "in 0:09")
        XCTAssertEqual(Now.countdownText(secondsAhead: 3_599, isApproximate: false), "in 59:59")
    }

    func testCountdownRoundsUpSoAMarginStillAheadNeverReadsZero() {
        XCTAssertEqual(Now.countdownText(secondsAhead: 0.2, isApproximate: false), "in 0:01")
        XCTAssertEqual(Now.countdownText(secondsAhead: 79.1, isApproximate: false), "in 1:20")
    }

    func testCountdownCountsDownWhilePlaying() {
        let texts = [0.0, 1, 2].map { elapsed in
            Now.rows(playhead: 100 + elapsed, margins: [margin("a", 105)]).first?.countdown
        }
        XCTAssertEqual(texts, ["in 0:05", "in 0:04", "in 0:03"])
    }

    func testAnHourOrMoreShowsHours() {
        XCTAssertEqual(Now.countdownText(secondsAhead: 3_600, isApproximate: false), "in 1:00:00")
        XCTAssertEqual(Now.countdownText(secondsAhead: 3_900, isApproximate: false), "in 1:05:00")
    }

    func testAnApproximatePositionSaysSo() {
        XCTAssertEqual(Now.countdownText(secondsAhead: 80, isApproximate: true), "in about 1:20")
        let rows = Now.rows(playhead: 0, margins: [margin("rough", 80, .shared, approximate: true)])
        XCTAssertEqual(rows.first?.countdown, "in about 1:20")
        XCTAssertEqual(rows.first?.isApproximate, true)
    }

    func testAnAbsurdlyFarPositionDoesNotTrap() {
        XCTAssertFalse(Now.countdownText(secondsAhead: 1e300, isApproximate: false).isEmpty)
    }
}
