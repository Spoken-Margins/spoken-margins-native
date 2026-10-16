import Foundation
import XCTest
@testable import SessionKit

/// #1681: live narration rendered the whole rest of the article ahead, hot or in the background.
final class RenderAheadPolicyTests: XCTestCase {
    func testOnlyACoolPhoneOnScreenWithPowerToSpareRendersWithoutLimit() {
        XCTAssertNil(RenderAheadPolicy.window(appBackgrounded: false, conditions: .init()))
        XCTAssertNil(RenderAheadPolicy.window(appBackgrounded: false, conditions: .init(thermal: .fair)))
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true, conditions: .init()), 300)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: false, conditions: .init(thermal: .serious)), 300)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: false, conditions: .init(isLowPowerModeEnabled: true)), 300)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: false, conditions: .init(thermal: .critical)), 60)
        XCTAssertEqual(RenderAheadPolicy.window(appBackgrounded: true, conditions: .init(thermal: .critical)), 60,
                       "critical keeps only what playback needs, wherever the app is")
        XCTAssertGreaterThanOrEqual(RenderAheadPolicy.window, RenderAheadPolicy.minimumWindow)
    }

    func testTheChainRestsAtTheWindowAndStartsAgainAtHalf() {
        let window = RenderAheadPolicy.window
        XCTAssertTrue(RenderAheadPolicy.rendersNext(listeningAhead: 299, window: window, resting: false))
        XCTAssertFalse(RenderAheadPolicy.rendersNext(listeningAhead: 300, window: window, resting: false))
        XCTAssertFalse(RenderAheadPolicy.rendersNext(listeningAhead: 151, window: window, resting: true),
                       "a resting chain waits until half is left")
        XCTAssertTrue(RenderAheadPolicy.rendersNext(listeningAhead: 150, window: window, resting: true))
        XCTAssertTrue(RenderAheadPolicy.rendersNext(listeningAhead: 10_000, window: nil, resting: true),
                      "no limit: a resting chain starts again at once")
    }

    /// Playing through an item on a fake clock: 20 s chunks, each rendered in 4 s, the chain stopping and starting
    /// by the policy. In the background the audio waiting ahead never passes the window plus one chunk, and never
    /// falls below half the window minus one chunk once it has filled, until the item's last chunk is rendered; in front on a cool phone it renders it all.
    func testPlayingThroughAnItemKeepsTheWindowFullWithoutRunningAway() {
        func simulate(backgrounded: Bool, conditions: SpeechEngineConditions, chunks: Int = 120)
            -> (maxAhead: TimeInterval, minAheadAfterFilling: TimeInterval, renderedAtMinute: Int) {
            let chunk: TimeInterval = 20, renderTime: TimeInterval = 4
            var rendered = 1, played: TimeInterval = 0, now: TimeInterval = 0, resting = false, renderDone: TimeInterval? = renderTime
            var maxAhead: TimeInterval = 0, minAhead = TimeInterval.infinity, filled = false, renderedAtMinute = 0
            let window = RenderAheadPolicy.window(appBackgrounded: backgrounded, conditions: conditions)
            while played < TimeInterval(chunks) * chunk {
                now += 1
                played = min(now, TimeInterval(rendered) * chunk)
                if let done = renderDone, now >= done {
                    rendered += 1
                    renderDone = nil
                }
                let ahead = max(0, TimeInterval(rendered) * chunk - played - chunk)
                maxAhead = max(maxAhead, ahead)
                if let window, ahead >= window { filled = true }
                if filled, rendered < chunks { minAhead = min(minAhead, ahead) } // the item's end drains it
                if Int(now) == 60 { renderedAtMinute = rendered }
                if renderDone == nil, rendered < chunks {
                    let next = RenderAheadPolicy.rendersNext(listeningAhead: ahead, window: window, resting: resting)
                    resting = !next
                    if next { renderDone = now + renderTime }
                }
            }
            return (maxAhead, minAhead, renderedAtMinute)
        }
        let away = simulate(backgrounded: true, conditions: .init())
        XCTAssertLessThanOrEqual(away.maxAhead, 300 + 20)
        XCTAssertGreaterThanOrEqual(away.minAheadAfterFilling, 150 - 20)
        let hot = simulate(backgrounded: false, conditions: .init(thermal: .critical))
        XCTAssertLessThanOrEqual(hot.maxAhead, 60 + 20)
        XCTAssertGreaterThan(hot.minAheadAfterFilling, 0, "playback never waits for a render")
        let cool = simulate(backgrounded: false, conditions: .init())
        XCTAssertEqual(cool.renderedAtMinute, 16, "on a cool phone in front it renders as fast as it can")
    }

    func testListeningIsAtTheListenersSpeed() {
        XCTAssertEqual(RenderAheadPolicy.listening(audioSeconds: 600, playbackRate: 2), 300)
        XCTAssertEqual(RenderAheadPolicy.listening(audioSeconds: 60, playbackRate: 0), 240)
    }
}
