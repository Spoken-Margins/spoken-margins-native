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

    func testAnItemWithNoTextShowsNoEstimate() {
        XCTAssertNil(ListeningTimeEstimator.libraryTotalText(textCharacterCount: nil, playbackSpeed: 1), "a podcast keeps its own clock")
        XCTAssertNil(ListeningTimeEstimator.libraryTotalText(textCharacterCount: 0, playbackSpeed: 1))
    }
}
