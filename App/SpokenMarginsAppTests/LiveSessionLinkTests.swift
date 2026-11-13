import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #2833: tapping the live session's Live Activity opens the live session, and its Write a Margin and Speak a
/// Margin links say which Margin to start.
@MainActor
final class LiveSessionLinkTests: XCTestCase {
    func testEveryActionRoundTripsThroughItsURL() {
        for action in [LiveSessionDeepLink.Action.open, .write, .speak, .photo] {
            XCTAssertEqual(LiveSessionDeepLink.action(from: LiveSessionDeepLink.url(action)), action)
        }
        XCTAssertEqual(LiveSessionDeepLink.url(.open).absoluteString, "spokenmargins://live-session")
        XCTAssertEqual(LiveSessionDeepLink.url(.speak).absoluteString, "spokenmargins://live-session?action=speak")
        XCTAssertEqual(LiveSessionDeepLink.url(.photo).absoluteString, "spokenmargins://live-session?action=photo")
    }

    func testOnlyLiveSessionLinksAreRecognised() throws {
        let rejected = [
            "spokenmargins://margin?session=a&margin=b",
            "spokenmargins://live-session/extra",
            "spokenmargins://live-session?action=erase",
            "spokenmargins://live-session?action=write&action=speak",
            "spokenmargins://live-session?action=photo&action=photo",
            "spokenmargins://live-session?action=photograph",
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

    func testOnlyALiveSessionURLIsTakenByTheRouter() throws {
        let router = LiveSessionLinkRouter()
        XCTAssertFalse(router.handle(try XCTUnwrap(URL(string: "spokenmargins://margin?session=a&margin=b"))))
        XCTAssertNil(router.cover)
        XCTAssertTrue(router.handle(LiveSessionDeepLink.url(.write)))
        XCTAssertNotNil(router.cover)
        XCTAssertEqual(router.takeAction(), .write)
    }

    // MARK: Photo (#2708)

    func testAPhotoLinkIsHandedOverOnceAndDroppedAfterTheTimeToLive() throws {
        let router = LiveSessionLinkRouter()
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(router.handle(LiveSessionDeepLink.url(.photo)))
        XCTAssertNotNil(router.cover)
        XCTAssertEqual(router.takeAction(), .photo)
        XCTAssertNil(router.takeAction())
        // A locked phone that sits on the unlock screen past the time to live gets no camera when it finally opens.
        router.open(.photo, now: opened)
        XCTAssertNil(router.takeAction(now: opened.addingTimeInterval(LiveSessionLinkRouter.timeToLive + 1)))
    }

    func testAPhotoLinkWithAScreenAlreadyOpenPresentsNothingElse() {
        let router = LiveSessionLinkRouter()
        router.runningScreenAppeared()
        router.open(.photo)
        XCTAssertNil(router.cover, "a second tap while the screen is up must not stack another screen")
        XCTAssertEqual(router.takeAction(), .photo)
    }

    func testTheCardOffersPhotoOnlyWhereTheSessionTakesPhotoMargins() {
        for kind in ElsewhereKind.allCases {
            let session = LiveSession(id: "s", kind: kind, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let state = LiveSessionActivities.runningState(for: session, markCount: 0, lastMarkAt: nil)
            XCTAssertEqual(state.offersPhoto == true, LiveSessionPhotoMargin.offers(kind), "\(kind)")
            let actions = LiveSessionMarginLink.links(offersPhoto: state.offersPhoto).map(\.action)
            XCTAssertEqual(actions.contains(.photo), LiveSessionPhotoMargin.offers(kind), "\(kind)")
        }
    }

    func testMeetingsAndAudiobooksKeepTodaysTwoLongLabelsAndAPhotoSessionGetsThreeShortOnes() {
        for offersPhoto in [nil, false] as [Bool?] {
            let links = LiveSessionMarginLink.links(offersPhoto: offersPhoto)
            XCTAssertEqual(links.map(\.title), ["Write a Margin", "Speak a Margin"])
            XCTAssertEqual(links.map(\.action), [.write, .speak])
        }
        let links = LiveSessionMarginLink.links(offersPhoto: true)
        XCTAssertEqual(links.map(\.title), ["Speak", "Write", "Photo"])
        XCTAssertEqual(links.map(\.action), [.speak, .write, .photo])
        // VoiceOver keeps the full names.
        XCTAssertEqual(links.map(\.accessibilityLabel), ["Speak a Margin", "Write a Margin", "Add a Margin with a photo"])
        // The words are the dock's: one place to change them.
        XCTAssertEqual(links[2].title, LiveSessionPhotoMargin.buttonTitle)
        XCTAssertEqual(links[2].accessibilityLabel, LiveSessionPhotoMargin.buttonAccessibilityLabel)
    }

    func testACardFromAnEarlierBuildDoesNotOfferPhotoAndTheFlagRoundTrips() throws {
        let old = #"{"markCount":2,"lastMarkAt":null}"#
        let state = try JSONDecoder().decode(LiveSessionActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertNil(state.offersPhoto)
        XCTAssertEqual(LiveSessionMarginLink.links(offersPhoto: state.offersPhoto).map(\.action), [.write, .speak])
        let photo = LiveSessionActivityAttributes.ContentState(markCount: 1, sessionId: "s", offersPhoto: true)
        let back = try JSONDecoder().decode(LiveSessionActivityAttributes.ContentState.self, from: JSONEncoder().encode(photo))
        XCTAssertEqual(back, photo)
        XCTAssertEqual(back.offersPhoto, true)
    }
}
