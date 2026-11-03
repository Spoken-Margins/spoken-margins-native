import XCTest
@testable import SessionKit

/// A friend's file opens straight onto its item (#3291): which files skip the sheet, and what is said on arrival.
final class SharedPacketArrivalTests: XCTestCase {
    func testAFriendsMarginsOpenTheirItemAndOnlyAListenersChoiceKeepsTheSheet() {
        XCTAssertEqual(SharedPacketArrival.route(isListeningMap: false, requiresRecipientItem: false), .openItem,
                       "an episode, an article or embedded text: nothing to decide")
        XCTAssertEqual(SharedPacketArrival.route(isListeningMap: false, requiresRecipientItem: true), .review,
                       "an audiobook or PDF only the listener has")
        XCTAssertEqual(SharedPacketArrival.route(isListeningMap: true, requiresRecipientItem: false), .review,
                       "a Listening Map can replace the one their copy has")
        XCTAssertEqual(SharedPacketArrival.route(isListeningMap: true, requiresRecipientItem: true), .review)
        XCTAssertEqual(
            SharedPacketArrival.route(isListeningMap: false, requiresRecipientItem: false, shownOnAnEarlierLaunch: true),
            .review, "a file kept in the inbox from an earlier launch waits for a tap")
    }

    /// First arrival: the item screen already says "From Cole · 3 Margins", so nothing more is said.
    func testAFirstArrivalSaysNothingMore() {
        XCTAssertNil(SharedPacketArrival.announcement(newMarginCount: 3, senderName: "Cole", itemHadFriendMargins: false))
    }

    /// The same file again, or a resend holding only Margins already here, opens the item silently.
    func testAFileWithNothingNewIsSilent() {
        XCTAssertNil(SharedPacketArrival.announcement(newMarginCount: 0, senderName: "Cole", itemHadFriendMargins: true))
        XCTAssertNil(SharedPacketArrival.announcement(newMarginCount: 0, senderName: "Cole", itemHadFriendMargins: false))
    }

    func testNewMarginsOnAnItemThatHadSomeAreCountedAndNamed() {
        let table: [(Int, String?, String)] = [
            (2, "Cole", "2 new Margins from Cole"),
            (1, "Cole", "1 new Margin from Cole"),
            (2, " Zoë \n", "2 new Margins from Zoë"),
            (2, "", "2 new Margins from your friend"),
            (2, "   ", "2 new Margins from your friend"),
            (2, nil, "2 new Margins from your friend"),
        ]
        for (count, name, expected) in table {
            XCTAssertEqual(
                SharedPacketArrival.announcement(newMarginCount: count, senderName: name, itemHadFriendMargins: true),
                expected, "\(String(describing: name))"
            )
        }
    }

    func testTheOpeningLineNamesTheSenderWhenThereIsOne() {
        XCTAssertEqual(SharedPacketArrival.openingMessage(senderName: "Cole"), "Opening Cole's Margins…")
        XCTAssertEqual(SharedPacketArrival.openingMessage(senderName: " "), "Opening your friend's Margins…")
        XCTAssertEqual(SharedPacketArrival.openingMessage(senderName: nil), "Opening your friend's Margins…")
    }
}
