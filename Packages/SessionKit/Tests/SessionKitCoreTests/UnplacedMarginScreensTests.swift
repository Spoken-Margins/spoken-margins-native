import Foundation
import XCTest
@testable import SessionKit

/// #4233, PR 3b: what the Margin details, the item screen and the error banner say and offer for a Margin moved from a
/// live session with no place on its item (`Interjection.hasPlace == false`). A placed Margin is the control in every row:
/// it reads exactly as it did before.
final class UnplacedMarginScreensTests: XCTestCase {
    private func margin(unplaced: Bool, moved: Bool = false, placeLabel: String? = nil, title: String = "Quick session") -> Interjection {
        var margin = Interjection(
            id: "m", itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), roughPercent: unplaced ? 0 : 40,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: unplaced ? 0 : 90_000),
            audioPath: "SpokenMargins/interjections/m.m4a", audioStatus: "recorded", transcriptionStatus: "transcribed",
            transcript: "Words.", cleanedTranscript: nil, displayText: "Words.", status: "active", captureKind: .audio)
        if unplaced || moved {
            margin.movedOrigin = MovedMarginOrigin(
                marginId: "m", itemId: "item", sessionId: "session", liveMarginId: "live-m", fromLiveSessionId: "live",
                fromLiveSessionTitle: title, sessionPlaceLabel: placeLabel, markedAt: margin.createdAt,
                movedAt: margin.createdAt.addingTimeInterval(60), placeKnown: !unplaced)
        }
        return margin
    }

    func testTheItemScreenLineSaysNoPlaceInsteadOfAZeroPercent() {
        XCTAssertEqual(MarginPlacePresentation.itemScreenLine(for: margin(unplaced: true)), "No place")
        XCTAssertEqual(MarginPlacePresentation.itemScreenLine(for: margin(unplaced: false)), "At 40%")
        // A Margin moved with a known place reads like one recorded there.
        XCTAssertEqual(MarginPlacePresentation.itemScreenLine(for: margin(unplaced: false, moved: true)), "At 40%")
    }

    func testTheDetailsOfferGoToAndShareOnlyForAMarginWithAPlace() {
        let table: [(String, Interjection, Bool, Bool)] = [
            ("recorded in place", margin(unplaced: false), true, true),
            ("moved with a known place", margin(unplaced: false, moved: true), true, true),
            ("moved with no place", margin(unplaced: true), false, false)
        ]
        for (name, margin, goTo, share) in table {
            XCTAssertEqual(MarginPlacePresentation.offersGoToMoment(margin), goTo, name)
            XCTAssertEqual(MarginPlacePresentation.offersShare(margin), share, name)
            // The row tap and the details agree.
            XCTAssertEqual(MarginRowTap.action(for: margin) == .playMoment, goTo, name)
        }
        var response = margin(unplaced: false)
        response.status = "deleted"
        XCTAssertFalse(MarginPlacePresentation.offersShare(response), "a Margin the Share sheet wouldn't list is still not offered")
    }

    func testMovedFromNamesTheSessionAndWhatItSaidAboutTheSource() {
        XCTAssertNil(MarginPlacePresentation.movedFromLine(for: margin(unplaced: false)), "never moved")
        XCTAssertEqual(MarginPlacePresentation.movedFromLine(for: margin(unplaced: true)), "Moved from “Quick session”")
        XCTAssertEqual(MarginPlacePresentation.movedFromLine(for: margin(unplaced: true, placeLabel: "about page 120")),
                       "Moved from “Quick session” · was about page 120")
        XCTAssertEqual(MarginPlacePresentation.movedFromLine(for: margin(unplaced: false, moved: true, placeLabel: " about 1:23:10 ")),
                       "Moved from “Quick session” · was about 1:23:10", "both kinds say where they came from")
        XCTAssertEqual(MarginPlacePresentation.movedFromLine(for: margin(unplaced: true, placeLabel: "  ", title: "  Mixed ")),
                       "Moved from “Mixed”", "an empty label adds nothing, and the title is trimmed")
    }

    func testTheDetailPositionIsNeverAZeroClockOrPercent() {
        XCTAssertEqual(MarginPlacePresentation.detailPosition, "No place saved")
        XCTAssertFalse(MarginPlacePresentation.detailPosition.contains("%"))
        XCTAssertFalse(MarginPlacePresentation.detailPosition.contains("0:00"))
    }

    func testTheBannerForATapOnAMarginWithNoPlaceIsAPlainSentence() {
        XCTAssertEqual(ListenerErrorText.message(for: MarginPlaceError.noPlace), "This Margin has no place in the source.")
        XCTAssertEqual(ListenerErrorText.line(prefix: "Could not play this Margin's position.", error: MarginPlaceError.noPlace),
                       "Could not play this Margin's position. This Margin has no place in the source.")
        XCTAssertFalse(ListenerErrorText.looksLikeCodeOrDump(MarginPlaceError.noPlace.errorDescription ?? ""))
    }
}
