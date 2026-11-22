import XCTest
@testable import SessionKit

/// #3862: a Timeline card speaks its item's own unit, and never invents a time.
final class TimelinePositionLabelTests: XCTestCase {
    // MARK: a card's label

    func testAMediaChapterWithAnExactStartShowsTheClockUnderAnHour() {
        let label = TimelinePositionLabel.label(kind: .media, startMs: 450_000, percent: 7)
        XCTAssertEqual(label, .init(corner: "7:30", spoken: "7 minutes, 30 seconds", chapterDetail: "Chapter · 7:30"))
    }

    func testAMediaChapterWithAnExactStartOverAnHourKeepsTheHours() {
        let label = TimelinePositionLabel.label(kind: .media, startMs: 4_050_000, percent: 65)
        XCTAssertEqual(label, .init(corner: "1:07:30", spoken: "1 hour, 7 minutes, 30 seconds", chapterDetail: "Chapter · 1:07:30"),
                       "not 67:30, and not the percentage the chapter also carries")
    }

    func testAMediaChapterPlacedOnlyByAFractionShowsThePercentAndSaysAbout() {
        let label = TimelinePositionLabel.label(kind: .media, startMs: nil, percent: 65)
        XCTAssertEqual(label, .init(corner: "65%", spoken: "65 percent", chapterDetail: "Chapter · about 65%"))
        XCTAssertFalse(label.corner.contains(":"), "no time is made from a percentage")
    }

    func testATextItemShowsPercentagesAndNeverATimeEvenIfOneIsGiven() {
        XCTAssertEqual(TimelinePositionLabel.label(kind: .text, startMs: nil, percent: 56),
                       .init(corner: "56%", spoken: "56 percent", chapterDetail: "Chapter · 56%"))
        XCTAssertEqual(TimelinePositionLabel.label(kind: .text, startMs: 500_000, percent: 56),
                       .init(corner: "56%", spoken: "56 percent", chapterDetail: "Chapter · 56%"), "no time leaks into any field")
    }

    func testANegativeStartIsNotAnExactTime() {
        XCTAssertEqual(TimelinePositionLabel.label(kind: .media, startMs: -500, percent: 40),
                       .init(corner: "40%", spoken: "40 percent", chapterDetail: "Chapter · about 40%"))
    }

    func testAVeryLargeStartDoesNotOverflow() {
        let label = TimelinePositionLabel.label(kind: .media, startMs: Int.max, percent: 100)
        XCTAssertTrue(label.corner.contains(":"), label.corner)
        XCTAssertTrue(label.spoken.contains("hour"), label.spoken)
    }

    func testTheStartOfTheItemIsZero() {
        XCTAssertEqual(TimelinePositionLabel.label(kind: .media, startMs: 0, percent: 0).corner, "0:00")
        XCTAssertEqual(TimelinePositionLabel.label(kind: .media, startMs: 0, percent: 0).spoken, "0 seconds")
        XCTAssertEqual(TimelinePositionLabel.label(kind: .text, startMs: nil, percent: 0).corner, "0%")
    }

    func testAPercentOutsideZeroToOneHundredIsClamped() {
        XCTAssertEqual(TimelinePositionLabel.label(kind: .text, startMs: nil, percent: 140).corner, "100%")
        XCTAssertEqual(TimelinePositionLabel.label(kind: .text, startMs: nil, percent: -3).corner, "0%")
    }

    // MARK: the listener's own percent

    func testTheMediaPercentRoundsDownSoNinetyNineNeverReadsAsFinished() {
        XCTAssertEqual(TimelinePositionLabel.mediaPercent(currentMs: 5_976, durationMs: 6_000), 99)
        XCTAssertEqual(TimelinePositionLabel.mediaPercent(currentMs: 6_000, durationMs: 6_000), 100)
        XCTAssertEqual(TimelinePositionLabel.mediaPercent(currentMs: 4_008_000, durationMs: 6_180_000), 64)
        XCTAssertEqual(TimelinePositionLabel.mediaPercent(currentMs: 0, durationMs: 6_000), 0)
    }

    func testTheMediaPercentIsClampedAndNilWithoutADuration() {
        XCTAssertEqual(TimelinePositionLabel.mediaPercent(currentMs: 9_000, durationMs: 6_000), 100)
        XCTAssertEqual(TimelinePositionLabel.mediaPercent(currentMs: -5, durationMs: 6_000), 0)
        XCTAssertNil(TimelinePositionLabel.mediaPercent(currentMs: 1_000, durationMs: nil))
        XCTAssertNil(TimelinePositionLabel.mediaPercent(currentMs: 1_000, durationMs: 0))
        XCTAssertNil(TimelinePositionLabel.mediaPercent(currentMs: 1_000, durationMs: -10))
    }

    // MARK: the current card's line

    func testTheCurrentLineOnMediaHasTheClockAndThePercent() {
        XCTAssertEqual(
            TimelinePositionLabel.currentLine(currentLabel: "Current chapter", currentMs: 4_008_000, percent: 64, isMedia: true),
            "Current chapter · 1:06:48 · 64%")
    }

    func testTheCurrentLineOnMediaWithAnUnknownDurationHasNoPercent() {
        XCTAssertEqual(
            TimelinePositionLabel.currentLine(currentLabel: "Current chapter", currentMs: 4_008_000, percent: nil, isMedia: true),
            "Current chapter · 1:06:48")
    }

    func testTheCurrentLineOnTextHasThePercentAndNoClock() {
        XCTAssertEqual(
            TimelinePositionLabel.currentLine(currentLabel: "Current chapter", currentMs: 99_000, percent: 47, isMedia: false),
            "Current chapter · 47%")
        XCTAssertEqual(
            TimelinePositionLabel.currentLine(currentLabel: "Current passage", currentMs: nil, percent: 47, isMedia: false),
            "Current passage · 47%")
    }

    func testTheCurrentLineWithNothingToAddIsTheLabel() {
        XCTAssertEqual(TimelinePositionLabel.currentLine(currentLabel: "Current chapter", currentMs: nil, percent: nil, isMedia: true), "Current chapter")
        XCTAssertEqual(TimelinePositionLabel.currentLine(currentLabel: "Current chapter", currentMs: nil, percent: nil, isMedia: false), "Current chapter")
    }

    func testTheCurrentLineAtNinetyNinePercentIsNotRoundedUp() {
        let percent = TimelinePositionLabel.mediaPercent(currentMs: 6_130_000, durationMs: 6_180_000)
        XCTAssertEqual(
            TimelinePositionLabel.currentLine(currentLabel: "Current chapter", currentMs: 6_130_000, percent: percent, isMedia: true),
            "Current chapter · 1:42:10 · 99%")
    }

    // MARK: the text scrubber's percent, shared with the Timeline

    func testTheTextScrubberPercentIsTheNearestWholePercentAndClamped() {
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 470, length: 1_000), 47)
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 474.9, length: 1_000), 47)
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 475, length: 1_000), 48)
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 0, length: 1_000), 0)
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 2_000, length: 1_000), 100)
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: -4, length: 1_000), 0)
    }

    func testTheTextScrubberPercentIsZeroWhileTheLengthIsUnknown() {
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 50, length: 0), 0)
        XCTAssertEqual(TimelinePositionLabel.textScrubberPercent(offset: 50, length: -1), 0)
    }

    // MARK: the media scrubber's spoken value

    func testTheMediaScrubberValueGainsTheSpokenPercent() {
        XCTAssertEqual(
            TimelinePositionLabel.appendingSpokenPercent(to: "1:06:48 of 1:43:00", currentMs: 4_008_000, durationMs: 6_180_000),
            "1:06:48 of 1:43:00, 64 percent")
    }

    func testTheMediaScrubberValueIsUnchangedWithoutADuration() {
        XCTAssertEqual(TimelinePositionLabel.appendingSpokenPercent(to: "1:06 of 0:00", currentMs: 66_000, durationMs: nil), "1:06 of 0:00")
        XCTAssertEqual(TimelinePositionLabel.appendingSpokenPercent(to: "1:06 of 0:00", currentMs: 66_000, durationMs: 0), "1:06 of 0:00")
    }
}
