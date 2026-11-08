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

    /// #3720: the tone-only card used to expire after 12 s whatever the listener was using, so a VoiceOver or Switch
    /// Control listener still reaching for Listen found it gone.
    func testToneOnlyCardWaitsForAnAnswerWhileAssistiveTechnologyRuns() {
        for mode in [ImportedCommentaryRevealMode.companion, .fresh, nil] {
            let style = SharedMarginPromptStyle.style(revealMode: mode, arrival: .crossed, assistiveTechnologyRunning: true)
            XCTAssertNil(style.expiresAfterMs, "no expiry for \(String(describing: mode))")
            XCTAssertFalse(style.pausesSource, "the episode still plays on; only the card stays")
            XCTAssertNil(style.autoPlayAfterMs)
        }
    }

    func testOtherListenersKeepTheTwelveSecondCardAndGuidedIsUnchanged() {
        XCTAssertEqual(SharedMarginPromptStyle.toneOnlyCardMs, 12_000)
        let plain = SharedMarginPromptStyle.style(revealMode: .companion, arrival: .crossed, assistiveTechnologyRunning: false)
        XCTAssertEqual(plain.expiresAfterMs, 12_000)
        for assistive in [false, true] {
            let guided = SharedMarginPromptStyle.style(revealMode: .guided, arrival: .crossed, assistiveTechnologyRunning: assistive)
            XCTAssertTrue(guided.pausesSource)
            XCTAssertEqual(guided.autoPlayAfterMs, 420)
            XCTAssertNil(guided.expiresAfterMs)
        }
    }

    /// Only the crossed, auto-play-off card may be replaced by the next Margin; auto-play and jumped-to cards may not.
    func testOnlyTheCrossedToneCardIsToneOnly() {
        for assistive in [false, true] {
            XCTAssertTrue(SharedMarginPromptStyle.style(revealMode: .companion, arrival: .crossed, assistiveTechnologyRunning: assistive).isToneOnly)
            XCTAssertFalse(SharedMarginPromptStyle.style(revealMode: .guided, arrival: .crossed, assistiveTechnologyRunning: assistive).isToneOnly)
            XCTAssertFalse(SharedMarginPromptStyle.style(revealMode: .companion, arrival: .jumpedTo, assistiveTechnologyRunning: assistive).isToneOnly)
        }
    }

    func testALayerWithNoRevealModeIsNotAutoPlay() {
        let style = SharedMarginPromptStyle.style(revealMode: nil, arrival: .crossed)
        XCTAssertNil(style.autoPlayAfterMs)
        XCTAssertFalse(style.pausesSource)
    }

    func testGoingToAMarginYourselfStillWaitsThereWithAutoPlayOff() {
        let style = SharedMarginPromptStyle.style(revealMode: .companion, arrival: .jumpedTo)
        XCTAssertTrue(style.pausesSource)
        XCTAssertNil(style.autoPlayAfterMs)
        XCTAssertNil(style.expiresAfterMs)
    }
}
