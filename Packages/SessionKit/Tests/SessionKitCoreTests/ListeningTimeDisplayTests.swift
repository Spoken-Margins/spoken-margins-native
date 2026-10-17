import XCTest
@testable import SessionKit

/// What the player and the Library show for a text item's listening time (#305, display half).
final class ListeningTimeDisplayTests: XCTestCase {
    func testTheScrubberReadsThePercentThenTheTimeLeftAndFollowsTheSpeed() throws {
        // 14 characters a second at 1x: 21 000 characters is 25 min; 10 080 left is 12 min.
        let atNormal = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 21_000, charactersHeard: 10_920, playbackSpeed: 1))
        XCTAssertEqual(atNormal.remainingText, "about 12 min left")
        XCTAssertEqual(atNormal.scrubberAccessibilityValue(percent: 52), "52 percent, about 12 minutes left")
        let atDouble = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 21_000, charactersHeard: 10_920, playbackSpeed: 2))
        XCTAssertEqual(atDouble.remainingText, "about 6 min left")
        XCTAssertEqual(atDouble.scrubberAccessibilityValue(percent: 52), "52 percent, about 6 minutes left")
        let atEnd = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 21_000, charactersHeard: 21_000, playbackSpeed: 1))
        XCTAssertEqual(atEnd.scrubberAccessibilityValue(percent: 100), "100 percent, less than a minute left")
    }

    func testALibraryRowShowsATextItemsTotalAtTheListenersSpeed() {
        XCTAssertEqual(ListeningTimeEstimator.libraryTotalText(textCharacterCount: 21_000, playbackSpeed: 1), "about 25 min")
        XCTAssertEqual(ListeningTimeEstimator.libraryTotalText(textCharacterCount: 21_000, playbackSpeed: 2), "about 13 min")
        XCTAssertEqual(ListeningTimeEstimator.libraryTotalText(textCharacterCount: 300, playbackSpeed: 1), "under 1 min")
    }

    func testTheLibraryCountsTheSameCharactersAsThePlayer() {
        // Codex audit on #832: the Library counted UTF-16 units while the player counts characters,
        // so 21 000 decomposed "é" (42 000 units) showed "about 50 min" in Library and 25 in the player.
        let decomposed = String(repeating: "e\u{301}", count: 21_000)
        XCTAssertEqual(ListeningTimeEstimator.characterCount(of: decomposed), decomposed.count)
        XCTAssertEqual(ListeningTimeEstimator.libraryTotalText(
            textCharacterCount: ListeningTimeEstimator.characterCount(of: decomposed), playbackSpeed: 1), "about 25 min")
        XCTAssertEqual(ListeningTimeEstimator.characterCount(of: "Café 🇨🇦"), 6)
        XCTAssertNil(ListeningTimeEstimator.characterCount(of: nil))
    }

    func testThePlainProgressBarStillShowsATextItemsTimeLeft() throws {
        // Codex audit on d75c55c: while starter audio is prepared the player shows a plain bar instead
        // of the scrubber, and that bar said "100%" with a bare percentage for VoiceOver.
        let estimate = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 21_000, charactersHeard: 10_920, playbackSpeed: 1))
        let starter = PlaybackProgressBarLabels(percent: 52, estimate: estimate)
        XCTAssertEqual(starter.trailing, "~12m left")
        XCTAssertEqual(starter.trailingSpokenText, "about 12 minutes left", "the label is its own VoiceOver element and speaks words, not \"~12m\"")
        XCTAssertEqual(starter.accessibilityValue, "52 percent, about 12 minutes left")
        let atDouble = PlaybackProgressBarLabels(percent: 52, estimate: ListeningTimeEstimator.estimate(totalCharacters: 21_000, charactersHeard: 10_920, playbackSpeed: 2))
        XCTAssertEqual(atDouble.trailing, "~6m left")
        let media = PlaybackProgressBarLabels(percent: 40, estimate: nil)
        XCTAssertEqual(media.trailing, "100%", "media with no known length keeps its percentage")
        XCTAssertEqual(media.trailingSpokenText, "100 percent")
        XCTAssertEqual(media.accessibilityValue, "40 percent")
    }

    func testTheVisibleTimeLeftIsCompactAndVoiceOverKeepsTheWords() throws {
        // 14 characters a second at 1x, so characters left = 14 x the seconds wanted.
        func estimate(secondsLeft: Double, speed: Double = 1) throws -> ListeningTimeEstimate {
            try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 1_000_000, charactersHeard: 1_000_000 - Int(secondsLeft * 14 * speed), playbackSpeed: speed))
        }
        let cases: [(String, Double, String, String)] = [
            ("under a minute", 59, "<1m left", "less than a minute left"),
            ("exactly one minute", 60, "~1m left", "about 1 minute left"),
            ("two minutes", 120, "~2m left", "about 2 minutes left"),
            ("rounds to the nearest minute", 89, "~1m left", "about 1 minute left"),
            ("an hour", 3_600, "~1h left", "about 1 hour left"),
            ("an hour and five minutes", 3_900, "~1h 5m left", "about 1 hour 5 minutes left"),
            ("two hours", 7_200, "~2h left", "about 2 hours left"),
        ]
        for (name, seconds, compact, spoken) in cases {
            let value = try estimate(secondsLeft: seconds)
            XCTAssertEqual(value.compactRemainingText, compact, name)
            XCTAssertEqual(value.remainingSpokenText, spoken, name)
            XCTAssertEqual(value.scrubberAccessibilityValue(percent: 40), "40 percent, \(spoken)", name)
        }
        // The same characters left at double speed take half the time, so the label follows the speed.
        let normal = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 100_000, charactersHeard: 100_000 - 14 * 600, playbackSpeed: 1))
        let double = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 100_000, charactersHeard: 100_000 - 14 * 600, playbackSpeed: 2))
        XCTAssertEqual(normal.compactRemainingText, "~10m left")
        XCTAssertEqual(double.compactRemainingText, "~5m left")
        // Past the end, and the existing long text, keep their meaning for any other caller.
        let end = try XCTUnwrap(ListeningTimeEstimator.estimate(totalCharacters: 1_000, charactersHeard: 5_000, playbackSpeed: 1))
        XCTAssertEqual(end.compactRemainingText, "<1m left")
        XCTAssertEqual(end.remainingText, "under 1 min left")
        XCTAssertEqual(normal.remainingText, "about 10 min left")
    }

    func testAnItemWithNoTextShowsNoEstimate() {
        XCTAssertNil(ListeningTimeEstimator.libraryTotalText(textCharacterCount: nil, playbackSpeed: 1), "a podcast keeps its own clock")
        XCTAssertNil(ListeningTimeEstimator.libraryTotalText(textCharacterCount: 0, playbackSpeed: 1))
    }
}
