import XCTest
@testable import SessionKit

/// #1054: when a PDF moves to a new extraction that keeps only one of two copies of a repeated
/// phrase (a running head, a repeated line), a Margin that was on the dropped copy must not land on
/// the survivor without a sign. Here the sign is the existing one: the Margin is not placed, so the
/// whole item stays on its old extraction with every Margin where the listener put it.
final class StructuredDocumentMigrationRepeatedPhraseTests: XCTestCase {
    private typealias Anchor = StructuredDocumentMigration.TextAnchor

    private let head = "J Biol 12"
    private let one = "Page one text.\n"
    private let two = "Page two text.\n"
    private let three = "Page three text."

    /// The old extraction repeats the running head between pages.
    private var old: String { one + head + "\n" + two + head + "\n" + three }

    /// `stored: true` gives the Margin the context the app stores (`SessionEngine.textAnchorShoulder`):
    /// the text before the Margin's start, and the text from its start on, through its own words.
    private func anchor(_ id: String, copy: Int, in text: String, stored: Bool = false) -> Anchor {
        let start = characterOffsets(of: head, in: text)[copy]
        let end = start + head.count
        guard stored else { return Anchor(id: id, start: start, end: end) }
        let characters = Array(text)
        return Anchor(
            id: id, start: start, end: end,
            before: String(characters[max(0, start - 120)..<start]),
            after: String(characters[start..<min(characters.count, start + 120)])
        )
    }

    /// Offsets counted in Characters, as the migration counts them.
    private func characterOffsets(of words: String, in text: String) -> [Int] {
        let characters = Array(text)
        let needle = Array(words)
        return (0...(characters.count - needle.count)).filter { Array(characters[$0..<($0 + needle.count)]) == needle }
    }

    private func range(of words: String, in text: String, copy: Int) -> Range<Int> {
        let start = characterOffsets(of: words, in: text)[copy]
        return start..<(start + words.count)
    }

    // MARK: The new extraction keeps the first copy and drops the second

    func testTheSecondCopyDroppedLeavesAMarginOnTheFirstCopyWhereItIs() {
        let new = one + head + "\n" + two + three
        for stored in [false, true] {
            XCTAssertEqual(
                StructuredDocumentMigration.place([anchor("first", copy: 0, in: old, stored: stored)], from: old, into: new),
                .moved(["first": range(of: head, in: new, copy: 0)]),
                "stored context: \(stored)"
            )
        }
    }

    func testTheSecondCopyDroppedDoesNotMoveItsMarginOntoTheFirstCopy() {
        let new = one + head + "\n" + two + three
        for stored in [false, true] {
            XCTAssertEqual(
                StructuredDocumentMigration.place([anchor("second", copy: 1, in: old, stored: stored)], from: old, into: new),
                .stays(unplaced: ["second"]),
                "stored context: \(stored)"
            )
        }
    }

    // MARK: The new extraction keeps the second copy and drops the first

    func testTheFirstCopyDroppedLeavesAMarginOnTheSecondCopyWhereItIs() {
        let new = one + two + head + "\n" + three
        for stored in [false, true] {
            XCTAssertEqual(
                StructuredDocumentMigration.place([anchor("second", copy: 1, in: old, stored: stored)], from: old, into: new),
                .moved(["second": range(of: head, in: new, copy: 0)]),
                "stored context: \(stored)"
            )
        }
    }

    func testTheFirstCopyDroppedDoesNotMoveItsMarginOntoTheSecondCopy() {
        let new = one + two + head + "\n" + three
        for stored in [false, true] {
            XCTAssertEqual(
                StructuredDocumentMigration.place([anchor("first", copy: 0, in: old, stored: stored)], from: old, into: new),
                .stays(unplaced: ["first"]),
                "stored context: \(stored)"
            )
        }
    }

    // MARK: One Margin that can't be placed keeps the whole item where it is

    func testAMarginOnTheDroppedCopyKeepsTheWholeItemOnItsOldExtraction() {
        let new = one + head + "\n" + two + three
        let outcome = StructuredDocumentMigration.place([
            anchor("on-first", copy: 0, in: old),
            anchor("on-second", copy: 1, in: old)
        ], from: old, into: new)
        guard case .stays(let unplaced) = outcome else { return XCTFail("expected the item to stay, got \(outcome)") }
        XCTAssertEqual(unplaced, ["on-second"], "the Margin on the surviving copy is placed; only the dropped one blocks")
    }

    // MARK: Both copies survive, or the phrase was never repeated

    func testBothCopiesKeptStillSettledByContext() {
        let new = "Header\n\n" + old
        XCTAssertEqual(
            StructuredDocumentMigration.place([
                anchor("first", copy: 0, in: old), anchor("second", copy: 1, in: old, stored: true)
            ], from: old, into: new),
            .moved(["first": range(of: head, in: new, copy: 0), "second": range(of: head, in: new, copy: 1)])
        )
    }

    func testAPhraseThatWasNeverRepeatedMovesAsBefore() {
        let single = "Page one text.\nJ Biol 12\nPage two text."
        let new = "Cover\n\nPage one text.\n\nJ Biol 12\n\nPage two text."
        XCTAssertEqual(
            StructuredDocumentMigration.place([anchor("only", copy: 0, in: single)], from: single, into: new),
            .moved(["only": range(of: head, in: new, copy: 0)])
        )
    }

    // MARK: The context the app stores is cut at the Margin's start, not after its words

    /// A Margin on the title, which also repeats as a running head in the old text; the new
    /// extraction drops the running heads. Nothing precedes the title, so only the words after it
    /// can say this is the same copy.
    func testATitleMarginSurvivesWhenTheRunningHeadsAreDropped() {
        let title = "Sleep and memory"
        let old = title + "\nWe measured sleep.\n" + title + "\nResults were clear.\n" + title + "\nEnd."
        let new = title + "\nWe measured sleep.\nResults were clear.\nEnd."
        let start = 0
        for stored in [false, true] {
            let characters = Array(old)
            let margin = stored
                ? Anchor(id: "title", start: start, end: title.count, before: "", after: String(characters[0..<min(120, characters.count)]))
                : Anchor(id: "title", start: start, end: title.count)
            XCTAssertEqual(
                StructuredDocumentMigration.place([margin], from: old, into: new),
                .moved(["title": 0..<title.count]),
                "stored context: \(stored)"
            )
        }
    }

    /// Re-extraction often changes only the space or newline in front of a phrase; the words after it still
    /// say which copy the Margin is on.
    func testAMarginKeepsItsCopyWhenOnlyTheWhitespaceBeforeItChanges() {
        let phrase = "The dose was low."
        let old = "Intro four. " + phrase + " Then more. Later four. " + phrase + " And the end."
        let new = "Intro four.\n" + phrase + " Then more. Later we saw the end."
        let characters = Array(old)
        let start = characterOffsets(of: phrase, in: old)[0]
        let end = start + phrase.count
        for stored in [false, true] {
            let margin = stored
                ? Anchor(id: "m", start: start, end: end, before: String(characters[max(0, start - 120)..<start]), after: String(characters[start..<min(characters.count, start + 120)]))
                : Anchor(id: "m", start: start, end: end)
            XCTAssertEqual(
                StructuredDocumentMigration.place([margin], from: old, into: new),
                .moved(["m": range(of: phrase, in: new, copy: 0)]),
                "stored context: \(stored)"
            )
        }
    }

    // MARK: A listening position follows the same rule

    func testAPositionOnADroppedRepeatedParagraphIsNotMovedOntoTheSurvivor() {
        let paragraph = "The quick brown fox jumps over the lazy dog again and again and again today."
        let old = "Intro one.\n" + paragraph + "\nMiddle part with other words.\n" + paragraph + "\nOutro part."
        let new = "Intro one.\n" + paragraph + "\nMiddle part with other words.\nOutro part."
        let first = characterOffsets(of: paragraph, in: old)[0]
        let second = characterOffsets(of: paragraph, in: old)[1]
        XCTAssertEqual(StructuredDocumentMigration.placePosition(first, from: old, into: new), 11)
        XCTAssertNil(StructuredDocumentMigration.placePosition(second, from: old, into: new))
    }
}
