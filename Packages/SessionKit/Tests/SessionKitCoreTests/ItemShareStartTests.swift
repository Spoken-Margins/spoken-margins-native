import XCTest
@testable import SessionKit

/// #4229: the item screen's Share opens the friend sheet when the listener has Margins of their own to send, and otherwise says
/// why there is nothing to share, in one of three messages. Each row names a starting state from the Design.
final class ItemShareStartTests: XCTestCase {
    private func nothingYet(_ message: String) -> ItemShareStart {
        .nothingYet(.init(title: "Nothing to share yet", message: message))
    }

    func testAnItemWithNoMarginsSaysShareSendsTheMarginsYouMakeHere() {
        XCTAssertEqual(ItemShareStart.start(ownMargins: [], hasFriendMargins: false), nothingYet(
            "Share sends the Margins you make here to a friend who has Spoken Margins. Add a Margin while you listen, then share it from here."))
    }

    func testMarginsThatAreAllDeletedCountAsNone() {
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("m1", status: "deleted")], hasFriendMargins: false),
                       nothingYet(ItemShareStart.noMarginsMessage))
    }

    func testMarginsOnlyOnASummaryOrAnAnswerGetTheSummaryMessage() {
        let message = "Margins made during a summary or a reply can't be sent to a friend yet. Add a Margin while you listen to the piece itself, then share it from here."
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("r1", target: .assistantTurn)], hasFriendMargins: false),
                       nothingYet(message))
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("r2", target: .summaryTurn)], hasFriendMargins: false),
                       nothingYet(message))
    }

    func testTheSummaryMessageWinsOverTheFriendMessage() {
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("r1", target: .summaryTurn)], hasFriendMargins: true),
                       nothingYet(ItemShareStart.onlyResponseMarginsMessage))
    }

    func testAFriendsMarginsAndNoneOfTheListenersOwnGetTheFriendMessage() {
        XCTAssertEqual(ItemShareStart.start(ownMargins: [], hasFriendMargins: true), nothingYet(
            "Share sends your own Margins, not the ones a friend sent you. Add a Margin of your own while you listen, then share it from here."))
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("m1", status: "deleted")], hasFriendMargins: true),
                       nothingYet(ItemShareStart.onlyFriendMarginsMessage))
    }

    func testOneActiveMarginOnTheSourceShares() {
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("m1")], hasFriendMargins: false), .share)
    }

    func testOwnMarginsPlusAFriendsLayerShare() {
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("m1")], hasFriendMargins: true), .share)
        XCTAssertEqual(ItemShareStart.start(ownMargins: [margin("m1"), margin("r1", target: .assistantTurn)], hasFriendMargins: true), .share,
                       "a source Margin is enough even when another sits on an answer")
    }

    func testTheTitleIsTheSameInEveryMessage() {
        let rows: [([Interjection], Bool)] = [([], false), ([], true), ([margin("r", target: .summaryTurn)], false)]
        for (margins, friend) in rows {
            guard case .nothingYet(let explanation) = ItemShareStart.start(ownMargins: margins, hasFriendMargins: friend) else {
                return XCTFail("expected an explanation")
            }
            XCTAssertEqual(explanation.title, "Nothing to share yet")
        }
    }

    /// The decision must agree with the sheet's own filter on every row, so Share never opens an empty sheet and never refuses a
    /// sheet that would have had Margins.
    func testItAgreesWithTheSheetsFilterOnEveryCombination() {
        let targets: [InterjectionTargetType] = [.item, .summaryTurn, .assistantTurn]
        for target in targets {
            for status in ["active", "deleted"] {
                for friend in [false, true] {
                    let margins = [margin("m", target: target, status: status)]
                    let sharesByFilter = margins.contains(where: ItemShareSessionSelection.isShareable)
                    let result = ItemShareStart.start(ownMargins: margins, hasFriendMargins: friend)
                    XCTAssertEqual(result == .share, sharesByFilter, "\(target) \(status) friend=\(friend)")
                }
            }
        }
    }

    private func margin(_ id: String, target: InterjectionTargetType = .item, status: String = "active") -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: target, targetId: target == .item ? "item" : "turn",
            createdAt: Date(timeIntervalSince1970: 0), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: id,
            cleanedTranscript: nil, displayText: id, status: status, captureKind: .written
        )
    }
}
