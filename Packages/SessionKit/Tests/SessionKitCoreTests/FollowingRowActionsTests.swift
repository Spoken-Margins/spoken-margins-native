import Foundation
import SessionKit
import XCTest

/// #478: every unfollow names the show, and a long or missing name never breaks the menu.
final class FollowingRowActionsTests: XCTestCase {
    func testUnfollowAndMuteNameTheShow() {
        XCTAssertEqual(FollowingRowActions.unfollowQuestion(showTitle: "Hard Fork"), "Unfollow Hard Fork?")
        XCTAssertEqual(FollowingRowActions.unfollowTitle(showTitle: "Hard Fork"), "Unfollow Hard Fork")
        XCTAssertEqual(FollowingRowActions.muteTitle(showTitle: "Hard Fork"), "Mute Hard Fork")
    }

    /// Neighbouring names: missing, empty, blank, padded, multi-line, at and over the limit, and
    /// characters that are one to the listener but several to the machine.
    func testShowNamesAreShortenedAndFallBackWhenMissing() {
        let limit = FollowingRowActions.maxShowCharacters
        let long = String(repeating: "a", count: limit + 1)
        let table: [(name: String, show: String?, question: String)] = [
            ("missing", nil, "Unfollow this feed?"),
            ("empty", "", "Unfollow this feed?"),
            ("blank", " \n\t ", "Unfollow this feed?"),
            ("padded", "  The   Daily \n", "Unfollow The Daily?"),
            ("at the limit", String(repeating: "a", count: limit), "Unfollow \(String(repeating: "a", count: limit))?"),
            ("one over", long, "Unfollow \(String(repeating: "a", count: limit))…?"),
            ("cut falls after a space", String(repeating: "a", count: limit - 1) + " bbbb", "Unfollow \(String(repeating: "a", count: limit - 1))…?"),
            ("emoji family", String(repeating: "👨‍👩‍👧‍👦", count: limit + 2), "Unfollow \(String(repeating: "👨‍👩‍👧‍👦", count: limit))…?"),
        ]
        for row in table {
            XCTAssertEqual(FollowingRowActions.unfollowQuestion(showTitle: row.show), row.question, row.name)
        }
        XCTAssertEqual(FollowingRowActions.unfollowTitle(showTitle: nil), "Unfollow")
        XCTAssertEqual(FollowingRowActions.muteTitle(showTitle: " "), "Mute this show")
    }
}
