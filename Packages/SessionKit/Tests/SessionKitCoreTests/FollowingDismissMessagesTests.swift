import Foundation
import SessionKit
import XCTest

/// #477: the Undo banner after Dismiss shares the app's top banner, so a long title must not make it tall.
final class FollowingDismissMessagesTests: XCTestCase {
    func testTheBannerNamesTheEntryAndOffersUndo() {
        XCTAssertEqual(FollowingDismissMessages.dismissed(title: "The Long Article"), "Dismissed The Long Article.")
        XCTAssertEqual(FollowingDismissMessages.undoTitle, "Undo")
        XCTAssertEqual(FollowingDismissMessages.undoAccessibilityLabel(title: "The Long Article"), "Undo Dismiss, The Long Article")
    }

    /// Neighbouring titles: long, multi-line, padded, empty, blank, and characters that are one to the
    /// listener but several to the machine.
    func testTitlesAreShortenedToOneLine() {
        let limit = ManualCompletionMessages.maxTitleCharacters
        let table: [(name: String, title: String, message: String, label: String)] = [
            ("at the limit", String(repeating: "a", count: limit), "Dismissed \(String(repeating: "a", count: limit)).", "Undo Dismiss, \(String(repeating: "a", count: limit))"),
            ("one over", String(repeating: "a", count: limit + 1), "Dismissed \(String(repeating: "a", count: limit))….", "Undo Dismiss, \(String(repeating: "a", count: limit + 1))"),
            ("line break", "Part one\nPart two", "Dismissed Part one Part two.", "Undo Dismiss, Part one Part two"),
            ("runs of blanks", "  Part   one \t two  ", "Dismissed Part one two.", "Undo Dismiss, Part one two"),
            ("empty", "", "Dismissed.", "Undo Dismiss"),
            ("only blanks", " \n\t ", "Dismissed.", "Undo Dismiss"),
            ("emoji family", String(repeating: "👨‍👩‍👧‍👦", count: limit + 2), "Dismissed \(String(repeating: "👨‍👩‍👧‍👦", count: limit))….", "Undo Dismiss, \(String(repeating: "👨‍👩‍👧‍👦", count: limit + 2))"),
        ]
        for row in table {
            XCTAssertEqual(FollowingDismissMessages.dismissed(title: row.title), row.message, row.name)
            XCTAssertEqual(FollowingDismissMessages.undoAccessibilityLabel(title: row.title), row.label, row.name)
        }
    }

    /// #4285: a followed show's episode says "Not for me"; a Quick Folder file keeps "Dismiss".
    func testAFollowedEpisodeSaysNotForMeAndAFileSaysDismiss() {
        XCTAssertEqual(FollowingDismissMessages.actionTitle(isFollowedEntry: true), "Not for me")
        XCTAssertEqual(FollowingDismissMessages.actionSystemImage(isFollowedEntry: true), "hand.thumbsdown")
        XCTAssertEqual(FollowingDismissMessages.actionTitle(isFollowedEntry: false), "Dismiss")
        XCTAssertEqual(FollowingDismissMessages.actionSystemImage(isFollowedEntry: false), "xmark")
    }

    func testTheNotForMeBannerIsShortenedLikeDismiss() {
        let limit = ManualCompletionMessages.maxTitleCharacters
        let table: [(name: String, title: String, message: String, label: String)] = [
            ("plain", "The Long Article", "Not for me: The Long Article.", "Undo Not for me, The Long Article"),
            ("one over", String(repeating: "a", count: limit + 1), "Not for me: \(String(repeating: "a", count: limit))….", "Undo Not for me, \(String(repeating: "a", count: limit + 1))"),
            ("line break", "Part one\nPart two", "Not for me: Part one Part two.", "Undo Not for me, Part one Part two"),
            ("runs of blanks", "  Part   one \t two  ", "Not for me: Part one two.", "Undo Not for me, Part one two"),
            ("empty", "", "Not for me.", "Undo Not for me"),
            ("only blanks", " \n\t ", "Not for me.", "Undo Not for me"),
        ]
        for row in table {
            XCTAssertEqual(FollowingDismissMessages.notForMe(title: row.title), row.message, row.name)
            XCTAssertEqual(FollowingDismissMessages.notForMeUndoAccessibilityLabel(title: row.title), row.label, row.name)
        }
    }
}
