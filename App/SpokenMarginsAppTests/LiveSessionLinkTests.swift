import XCTest
@testable import SpokenMarginsApp

/// #2833: tapping the live session's Live Activity opens the live session, and its Write a Margin and Speak a
/// Margin links say which Margin to start.
@MainActor
final class LiveSessionLinkTests: XCTestCase {
    func testEveryActionRoundTripsThroughItsURL() {
        for action in [LiveSessionDeepLink.Action.open, .write, .speak] {
            XCTAssertEqual(LiveSessionDeepLink.action(from: LiveSessionDeepLink.url(action)), action)
        }
        XCTAssertEqual(LiveSessionDeepLink.url(.open).absoluteString, "spokenmargins://live-session")
        XCTAssertEqual(LiveSessionDeepLink.url(.speak).absoluteString, "spokenmargins://live-session?action=speak")
    }

    func testOnlyLiveSessionLinksAreRecognised() throws {
        let rejected = [
            "spokenmargins://margin?session=a&margin=b",
            "spokenmargins://live-session/extra",
            "spokenmargins://live-session?action=erase",
            "spokenmargins://live-session?action=write&action=speak",
            "https://live-session?action=write",
            "spokenmargins://elsewhere?action=write",
        ]
        for text in rejected {
            XCTAssertNil(LiveSessionDeepLink.action(from: try XCTUnwrap(URL(string: text))), text)
        }
        XCTAssertEqual(LiveSessionDeepLink.action(from: try XCTUnwrap(URL(string: "SpokenMargins://Live-Session/"))), .open)
    }

    func testALinkWithNoScreenOpenPresentsOneAndHandsOverTheActionOnce() {
        let router = LiveSessionLinkRouter()
        router.open(.speak)
        XCTAssertNotNil(router.cover)
        XCTAssertEqual(router.takeAction(), .speak)
        XCTAssertNil(router.takeAction())
    }

    func testALinkWithAScreenAlreadyOpenPresentsNothingElse() {
        let router = LiveSessionLinkRouter()
        router.runningScreenAppeared()
        router.open(.write)
        XCTAssertNil(router.cover)
        XCTAssertEqual(router.takeAction(), .write)
        router.runningScreenDisappeared()
        router.open(.open)
        XCTAssertNotNil(router.cover)
    }

    func testALinkNobodyActsOnSoonIsDroppedAndDismissingTheScreenDropsIt() {
        let router = LiveSessionLinkRouter()
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        router.open(.speak, now: opened)
        XCTAssertNil(router.takeAction(now: opened.addingTimeInterval(LiveSessionLinkRouter.timeToLive + 1)))
        router.open(.speak, now: opened)
        router.cover = nil
        XCTAssertNil(router.takeAction(now: opened))
    }
}
