import XCTest
@testable import SessionKit

/// #638: a Margin link opens its timeline unless another session is actually playing.
final class MarginTimelineOpeningTests: XCTestCase {
    func testAPausedSessionFromAnotherItemGivesWayToTheMarginsSession() {
        // The cold-launch case: the app restored another session paused, without autoplay.
        XCTAssertEqual(
            MarginTimelineOpening.decide(loadedSessionID: "session-restored", marginSessionID: "session-linked", loadedSessionIsPlaying: false),
            .openMarginSession
        )
    }

    func testAPlayingSessionIsLeftInNowPlaying() {
        XCTAssertEqual(
            MarginTimelineOpening.decide(loadedSessionID: "session-playing", marginSessionID: "session-linked", loadedSessionIsPlaying: true),
            .keepNowPlaying
        )
    }

    func testTheMarginsOwnSessionIsFocusedWhetherOrNotItPlays() {
        for playing in [false, true] {
            XCTAssertEqual(
                MarginTimelineOpening.decide(loadedSessionID: "session-linked", marginSessionID: "session-linked", loadedSessionIsPlaying: playing),
                .focusLoadedSession
            )
        }
    }

    func testWithNothingLoadedTheMarginsSessionOpens() {
        XCTAssertEqual(
            MarginTimelineOpening.decide(loadedSessionID: nil, marginSessionID: "session-linked", loadedSessionIsPlaying: false),
            .openMarginSession
        )
    }
}
