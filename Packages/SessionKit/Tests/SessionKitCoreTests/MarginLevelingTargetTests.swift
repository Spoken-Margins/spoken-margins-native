import Foundation
import XCTest
@testable import SessionKit

/// #467: which loudness a spoken Margin is leveled to, and which stretch of the episode sets it.
final class MarginLevelingTargetTests: XCTestCase {
    private func measurement(_ integrated: Double?) -> LoudnessMeasurement {
        LoudnessMeasurement(integratedLUFS: integrated, truePeakDBTP: -3, noiseFloorDBFS: -60)
    }

    // MARK: Target

    func testWithoutAnEpisodeWindowTheMarginPlaysAtThePodcastLevel() {
        XCTAssertEqual(MarginLevelingTarget.targetLUFS(sourceWindow: nil), -16)
        XCTAssertEqual(MarginLevelingTarget.fixedLUFS, LoudnessLeveling.defaultTargetLUFS)
    }

    func testAnEpisodeWindowSetsTheTargetOnTheCacheGrid() {
        XCTAssertEqual(MarginLevelingTarget.targetLUFS(sourceWindow: measurement(-19)), -19)
        XCTAssertEqual(MarginLevelingTarget.targetLUFS(sourceWindow: measurement(-19.2)), -19)
        XCTAssertEqual(MarginLevelingTarget.targetLUFS(sourceWindow: measurement(-19.3)), -19.5)
        XCTAssertEqual(MarginLevelingTarget.targetLUFS(sourceWindow: measurement(-16.26)), -16.5)
    }

    func testNeighbouringMeasurementsAndTheirFallbacks() {
        let cases: [(Double?, Double, String)] = [
            (nil, -16, "silence has no loudness: the gate found nothing"),
            (-70, -16, "far under the silent-window bound"),
            (-40.1, -16, "a hair under the silent-window bound"),
            (-40, -30, "at the silent-window bound the match is held at the quietest"),
            (-35, -30, "quiet stretch held at the quietest match"),
            (-30, -30, "quietest match itself"),
            (-12, -12, "loudest match itself"),
            (-11.9, -12, "a hair over the loudest match"),
            (-6, -12, "brickwalled stretch held at the loudest match"),
            (0, -12, "far over"),
            (Double.nan, -16, "not a number"),
            (Double.infinity, -16, "infinite"),
            (-Double.infinity, -16, "negative infinite")
        ]
        for (integrated, expected, why) in cases {
            XCTAssertEqual(MarginLevelingTarget.targetLUFS(sourceWindow: measurement(integrated)), expected, why)
        }
    }

    func testTheTargetNeverLeavesTheBoundsForAnyMeasurement() {
        for tenth in stride(from: -900, through: 100, by: 7) {
            let target = MarginLevelingTarget.targetLUFS(sourceWindow: measurement(Double(tenth) / 10))
            XCTAssertTrue(
                target == MarginLevelingTarget.fixedLUFS
                    || (MarginLevelingTarget.quietestMatchLUFS...MarginLevelingTarget.loudestMatchLUFS).contains(target),
                "\(Double(tenth) / 10) LUFS gave \(target)"
            )
        }
    }

    // MARK: Window

    func testTheWindowIsThirtySecondsEachSideOfTheAnchor() {
        let window = MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 600_000, sourceDurationMs: 3_600_000)
        XCTAssertEqual(window, MarginLevelingTarget.Window(startMs: 570_000, durationMs: 60_000))
    }

    func testTheWindowStaysInsideTheEpisode() {
        XCTAssertEqual(
            MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 5_000, sourceDurationMs: 3_600_000),
            MarginLevelingTarget.Window(startMs: 0, durationMs: 35_000), "near the start")
        XCTAssertEqual(
            MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 3_590_000, sourceDurationMs: 3_600_000),
            MarginLevelingTarget.Window(startMs: 3_560_000, durationMs: 40_000), "near the end")
        XCTAssertEqual(
            MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 3_600_000, sourceDurationMs: 3_600_000),
            MarginLevelingTarget.Window(startMs: 3_570_000, durationMs: 30_000), "at the very end")
        XCTAssertEqual(
            MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: -4_000, sourceDurationMs: 3_600_000),
            MarginLevelingTarget.Window(startMs: 0, durationMs: 30_000), "a negative anchor counts as the start")
    }

    func testWithoutAKnownLengthTheWindowIsNotCut() {
        XCTAssertEqual(
            MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 600_000, sourceDurationMs: nil),
            MarginLevelingTarget.Window(startMs: 570_000, durationMs: 60_000))
    }

    func testTooLittleEpisodeToMeasureGivesNoWindow() {
        // 2.9 s left after the anchor's start: not enough audio for a loudness reading.
        XCTAssertNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 600_000, sourceDurationMs: 572_900))
        // The anchor is past the end of the file.
        XCTAssertNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 700_000, sourceDurationMs: 600_000))
        // A zero-length file.
        XCTAssertNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 0, sourceDurationMs: 0))
        // Exactly the minimum is enough.
        XCTAssertNotNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: 600_000, sourceDurationMs: 573_000))
    }

    func testAHugeAnchorFromAnImportedPacketIsSafe() {
        XCTAssertNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: Int.max, sourceDurationMs: 3_600_000))
        XCTAssertNotNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: Int.max, sourceDurationMs: nil), "no length: nothing to compare with")
        XCTAssertNil(MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: Int.min, sourceDurationMs: 2_000))
        let window = MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: Int.max, sourceDurationMs: nil)
        XCTAssertLessThanOrEqual(window?.startMs ?? .max, MarginLevelingTarget.maximumAnchorMs, "no start beyond any real episode")
    }

    func testWhatCountsAsAnEpisodeWorthMatching() {
        XCTAssertFalse(MarginLevelingTarget.isMatchable(nil))
        XCTAssertFalse(MarginLevelingTarget.isMatchable(measurement(nil)))
        XCTAssertFalse(MarginLevelingTarget.isMatchable(measurement(-41)))
        XCTAssertFalse(MarginLevelingTarget.isMatchable(measurement(Double.nan)))
        XCTAssertTrue(MarginLevelingTarget.isMatchable(measurement(-40)))
        XCTAssertTrue(MarginLevelingTarget.isMatchable(measurement(-16)))
    }

    func testTheCacheGridRoundsToHalfADecibel() {
        XCTAssertEqual(MarginLevelingTarget.rounded(-16), -16)
        XCTAssertEqual(MarginLevelingTarget.rounded(-16.24), -16)
        XCTAssertEqual(MarginLevelingTarget.rounded(-16.26), -16.5)
        XCTAssertEqual(MarginLevelingTarget.rounded(-16.74), -16.5)
        XCTAssertEqual(MarginLevelingTarget.rounded(-16.76), -17)
    }
}
