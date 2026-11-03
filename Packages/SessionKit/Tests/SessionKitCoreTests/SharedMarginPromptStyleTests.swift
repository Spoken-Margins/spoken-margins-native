import XCTest
@testable import SessionKit

/// #3059: auto-play plays a friend's Margin in place; with it off the listener hears a tone and the episode plays on.
final class SharedMarginPromptStyleTests: XCTestCase {
    func testGuidedPausesAndPlaysTheMarginByItself() {
        for arrival in [SharedMarginPromptStyle.Arrival.crossed, .jumpedTo] {
            let style = SharedMarginPromptStyle.style(revealMode: .guided, arrival: arrival)
            XCTAssertTrue(style.pausesSource)
            XCTAssertEqual(style.autoPlayAfterMs, 420)
            XCTAssertNil(style.expiresAfterMs)
        }
    }

    func testToneOnlyLeavesTheEpisodePlayingAndLetsTheCardExpire() {
        for mode in [ImportedCommentaryRevealMode.companion, .fresh] {
            let style = SharedMarginPromptStyle.style(revealMode: mode, arrival: .crossed)
            XCTAssertFalse(style.pausesSource, "a tone, not a stop")
            XCTAssertNil(style.autoPlayAfterMs, "the listener taps to hear it")
            XCTAssertEqual(style.expiresAfterMs, SharedMarginPromptStyle.toneOnlyCardMs, "so the next Margin can be offered")
        }
    }

    func testGoingToAMarginYourselfStillWaitsThereWithAutoPlayOff() {
        let style = SharedMarginPromptStyle.style(revealMode: .companion, arrival: .jumpedTo)
        XCTAssertTrue(style.pausesSource)
        XCTAssertNil(style.autoPlayAfterMs)
        XCTAssertNil(style.expiresAfterMs)
    }
}
