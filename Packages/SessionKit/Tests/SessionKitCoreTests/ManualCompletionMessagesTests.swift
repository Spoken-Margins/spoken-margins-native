import Foundation
import SessionKit
import XCTest

/// #1149: the completion banner shares the app's top banner, so a long title must not make it tall.
final class ManualCompletionMessagesTests: XCTestCase {
    func testShortTitlesReadAsTheyDid() {
        XCTAssertEqual(ManualCompletionMessages.completed(title: "The Long Article"), "Marked The Long Article complete.")
        XCTAssertEqual(ManualCompletionMessages.undone(title: "The Long Article"), "Undid Mark Complete for The Long Article.")
        XCTAssertEqual(ManualCompletionMessages.unfinished(title: "The Long Article"), "Marked The Long Article unfinished.")
        XCTAssertEqual(ManualCompletionMessages.undoTitle, "Undo")
    }

    /// The neighbours of the cut: just under, exactly at and just over the limit; a break or a run of
    /// spaces inside a title; a title that is empty or only blanks; and characters that are one to the
    /// listener but several to the machine.
    func testTitlesAreShortenedToOneLineAtTheLimit() {
        let limit = ManualCompletionMessages.maxTitleCharacters
        var table: [(name: String, title: String, shown: String)] = []
        table.append(("just under", String(repeating: "a", count: limit - 1), String(repeating: "a", count: limit - 1)))
        table.append(("at the limit", String(repeating: "a", count: limit), String(repeating: "a", count: limit)))
        table.append(("one over", String(repeating: "a", count: limit + 1), String(repeating: "a", count: limit) + "…"))
        table.append(("very long", String(repeating: "word ", count: 200), String(repeating: "word ", count: 7) + "w…"))
        table.append(("cut falls after a space", String(repeating: "a", count: limit - 1) + " bbbb", String(repeating: "a", count: limit - 1) + "…"))
        table.append(("line break", "Part one\nPart two", "Part one Part two"))
        table.append(("runs of blanks", "  Part   one \t two  ", "Part one two"))
        table.append(("empty", "", ""))
        table.append(("only blanks", " \n\t ", ""))
        table.append(("emoji family", String(repeating: "👨‍👩‍👧‍👦", count: limit + 2), String(repeating: "👨‍👩‍👧‍👦", count: limit) + "…"))
        table.append(("combining accent", String(repeating: "e\u{301}", count: limit + 2), String(repeating: "e\u{301}", count: limit) + "…"))
        table.append(("CJK", String(repeating: "日", count: limit + 1), String(repeating: "日", count: limit) + "…"))
        table.append(("quotes and punctuation", "\"Why?\" & other questions: a talk", "\"Why?\" & other questions: a talk"))
        for row in table {
            XCTAssertEqual(ManualCompletionMessages.shortened(row.title), row.shown, row.name)
        }
    }

    func testAMessageForAnUntitledItemStillReads() {
        XCTAssertEqual(ManualCompletionMessages.completed(title: ""), "Marked complete.")
        XCTAssertEqual(ManualCompletionMessages.completed(title: "  \n "), "Marked complete.")
        XCTAssertEqual(ManualCompletionMessages.undone(title: ""), "Undid Mark Complete.")
        XCTAssertEqual(ManualCompletionMessages.unfinished(title: ""), "Marked unfinished.")
        XCTAssertEqual(ManualCompletionMessages.undoAccessibilityLabel(title: ""), "Undo Mark Complete")
    }

    func testALongTitleKeepsTheBannerShort() {
        let title = "What if automating AI R&D triggers an intelligence explosion? A very long episode title"
        for message in [
            ManualCompletionMessages.completed(title: title),
            ManualCompletionMessages.undone(title: title),
            ManualCompletionMessages.unfinished(title: title),
        ] {
            XCTAssertLessThanOrEqual(message.count, 64, message)
            XCTAssertFalse(message.contains("\n"), message)
        }
    }

    /// VoiceOver names the whole item with the button, even when the banner shows only the start of it.
    func testVoiceOverNamesTheWholeItemWithTheUndoButton() {
        let title = "What if automating AI R&D triggers an intelligence explosion? A very long episode title"
        XCTAssertEqual(
            ManualCompletionMessages.undoAccessibilityLabel(title: title),
            "Undo Mark Complete, \(title)"
        )
        XCTAssertEqual(
            ManualCompletionMessages.undoAccessibilityLabel(title: "Part one\nPart  two"),
            "Undo Mark Complete, Part one Part two"
        )
    }
}
