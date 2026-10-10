import XCTest
@testable import SessionKit

/// #943: the system player showed audio running (a nonzero rate extrapolates the clock) while the
/// engine was still starting.
final class SystemPlaybackPresentationTests: XCTestCase {
    private func presentation(_ status: PlaybackStatus, rate: Double = 1.25, narration: Bool = false) -> SystemPlaybackPresentation {
        SystemPlaybackPresentation(status: status, selectedRate: rate, isNarration: narration)
    }

    func testOnlyConfirmedPlaybackPublishesARunningRate() {
        XCTAssertEqual(presentation(.playing).playbackRate, 1.25)
        for status in [PlaybackStatus.starting, .paused, .idle, .failed, .recording] {
            XCTAssertEqual(presentation(status).playbackRate, 0, "\(status)")
        }
    }

    func testAPendingStartSaysLoadingForMediaAndPreparingForNarration() {
        XCTAssertEqual(presentation(.starting).loadingLine, "Loading audio…")
        XCTAssertEqual(presentation(.starting, narration: true).loadingLine, "Preparing voice…")
    }

    func testNoLoadingLineOnceStartedOrWhenNotStarting() {
        for status in [PlaybackStatus.playing, .paused, .idle, .failed, .recording] {
            XCTAssertNil(presentation(status).loadingLine, "\(status)")
        }
    }

    func testTheOldRuleWasWrongForStarting() {
        // The old mapping: rate = isPlaybackActive ? selected : 0. That is true for `starting`.
        XCTAssertTrue(PlaybackStatus.starting.isPlaybackActive)
        XCTAssertNotEqual(presentation(.starting).playbackRate, PlaybackStatus.starting.isPlaybackActive ? 1.25 : 0)
    }

    func testEverySelectableSpeedStaysZeroWhileStarting() {
        for rate in SpeechRateRule.supportedMultipliers {
            XCTAssertEqual(presentation(.starting, rate: rate).playbackRate, 0)
            XCTAssertEqual(presentation(.playing, rate: rate).playbackRate, rate)
        }
    }

    func testAPlayerThatIsWaitingEarnsNoRunningClockEvenWhenTheListenerWantsPlayback() {
        // AVPlayer path: play() was called (intent) but the stream is still opening or rebuffering.
        func rate(intent: Bool, waiting: Bool) -> Double {
            SystemPlaybackPresentation.playerRate(isPlayingByIntent: intent, isWaitingForPlayer: waiting, selectedRate: 1.5)
        }
        XCTAssertEqual(rate(intent: true, waiting: false), 1.5)
        XCTAssertEqual(rate(intent: true, waiting: true), 0)
        XCTAssertEqual(rate(intent: false, waiting: false), 0)
        XCTAssertEqual(rate(intent: false, waiting: true), 0)
    }

    func testResumeAfterPauseDoesNotRunTheClockUntilConfirmed() {
        // paused -> resume requested (starting) -> confirmed (playing)
        let rates = [PlaybackStatus.paused, .starting, .playing].map { presentation($0).playbackRate }
        XCTAssertEqual(rates, [0, 0, 1.25])
    }
}
