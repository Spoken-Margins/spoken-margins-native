import Foundation
import XCTest
@testable import SessionKit

/// #3777 PR 1: which footnote citations in an article pair with a definition. A note is matched only when
/// that is certain; every row that is not certain must come back unmatched, so the narrator keeps today's
/// "footnote 3" and the closing notes chapter.
final class FootnoteAnchorsTests: XCTestCase {
    private func slice(_ text: String, _ range: Range<Int>) -> String {
        let characters = Array(text)
        return String(characters[range])
    }

    // MARK: - Pairing

    func testOneNotePairsItsCitationWithItsDefinition() throws {
        let text = "The tide turns twice a day.[^1] Then it rests.\n\n[^1]: Smith, Tides, 2020."
        let anchors = FootnoteAnchors.find(in: text)
        let anchor = try XCTUnwrap(anchors.first)
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchor.label, "1")
        XCTAssertEqual(slice(text, anchor.citationRange), "[^1]")
        XCTAssertEqual(slice(text, anchor.definitionRange), "[^1]: Smith, Tides, 2020.")
        XCTAssertEqual(anchor.text, "Smith, Tides, 2020.")
        XCTAssertEqual(anchor.laterCitationRanges, [])
    }

    func testThreeNotesComeBackInTheOrderTheyAreCited() throws {
        let text = """
        First claim.[^b] Second claim.[^a] Third claim.[^c]

        [^a]: Note A.
        [^b]: Note B.
        [^c]: Note C.
        """
        let anchors = FootnoteAnchors.find(in: text)
        XCTAssertEqual(anchors.map(\.label), ["b", "a", "c"])
        XCTAssertEqual(anchors.map(\.text), ["Note B.", "Note A.", "Note C."])
        for anchor in anchors {
            XCTAssertEqual(slice(text, anchor.citationRange), "[^\(anchor.label)]")
            XCTAssertTrue(slice(text, anchor.definitionRange).hasPrefix("[^\(anchor.label)]:"))
        }
    }

    func testTwoCitationsOfOneNoteBelongToTheFirstAndTheSecondIsLater() throws {
        let text = "One.[^1] Two. Three.[^1]\n\n[^1]: The note."
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: text).first)
        XCTAssertEqual(anchor.citationRange, 4..<8)
        XCTAssertEqual(anchor.laterCitationRanges, [20..<24])
        XCTAssertEqual(anchor.citationRanges, [4..<8, 20..<24])
        XCTAssertEqual(slice(text, anchor.laterCitationRanges[0]), "[^1]")
    }

    func testLabelsMayBeNumbersLettersOrWords() {
        let text = "A.[^1] B.[^a] C.[^note-1] D.[^Note_2]\n\n[^1]: one\n[^a]: two\n[^note-1]: three\n[^Note_2]: four"
        let anchors = FootnoteAnchors.find(in: text)
        XCTAssertEqual(anchors.map(\.label), ["1", "a", "note-1", "Note_2"])
        XCTAssertEqual(anchors.map(\.text), ["one", "two", "three", "four"])
    }

    func testLabelsAreCaseSensitiveSoALookalikeIsNotMatched() {
        let text = "Claim.[^A]\n\n[^a]: Lowercase note."
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    // MARK: - Not certain: left alone

    func testACitationWithoutADefinitionIsNotMatched() {
        let text = "Claim.[^1] Another.[^2]\n\n[^1]: Only the first."
        let anchors = FootnoteAnchors.find(in: text)
        XCTAssertEqual(anchors.map(\.label), ["1"])
    }

    func testADefinitionWithoutACitationIsNotMatched() {
        let text = "No markers here.\n\n[^1]: Orphan.\n[^2]: Orphan too."
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    func testALabelDefinedTwiceIsNotMatchedAtAll() {
        let text = "Claim.[^1] Other.[^2]\n\n[^1]: First wording.\n[^1]: Second wording.\n[^2]: Fine."
        XCTAssertEqual(FootnoteAnchors.find(in: text).map(\.label), ["2"])
    }

    func testACitationAfterTheDefinitionDoesNotCount() {
        let text = "[^1]: Defined before any citation.\n\nLater claim.[^1]"
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    func testACitationInsideTheNotesSectionDoesNotCount() {
        // Note 2 cites note 1 from its own words, but nothing in the body cites 1.
        let body = "Body claim.[^2]\n\n"
        let notes = "[^1]: The base.\n[^2]: Builds on note one.[^1]"
        let text = body + notes
        let anchors = FootnoteAnchors.find(in: text, notesStartChar: body.count)
        XCTAssertEqual(anchors.map(\.label), ["2"])
        XCTAssertEqual(anchors.first?.text, "Builds on note one.[^1]")
    }

    func testACitationBeforeAMidArticleDefinitionStillNeedsToPrecedeIt() {
        let text = "Claim.[^1]\n\n[^1]: Mid note.\n\nMore body.[^1]\n\n[^2]: Closing."
        let anchor = FootnoteAnchors.find(in: text).first
        XCTAssertEqual(anchor?.label, "1")
        XCTAssertEqual(anchor?.laterCitationRanges, [], "the citation after its definition is not counted")
    }

    // MARK: - Text that only looks like a footnote

    func testBracketedNumbersWithoutACaretAreCitationsNotFootnotes() {
        let text = "Prior work [3] and [4] says so.\n\n[3]: Smith 2020.\n[4]: Jones 2021."
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    func testAMarkerInsideAFencedBlockIsNotACitationOrDefinition() {
        let text = "Intro.[^1]\n\n```\nExample.[^2]\n[^2]: inside a fence\n```\n\n[^1]: Real note.\n[^2]: Other real note."
        XCTAssertEqual(FootnoteAnchors.find(in: text).map(\.label), ["1"])
    }

    func testAMarkerWithWhitespaceOrNoLabelIsNotACitation() {
        let text = "One [^ 1] two [^] three [^1 2].\n\n[^1]: Unused."
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    func testAPdfShapedItemMatchesNothing() {
        let text = """
        Introduction

        The estimate was 4.2 percent3 in the first year.

        3 Source: Statistical Office, 2019, table 4.
        """
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    func testEmptyAndMarkerFreeTextMatchNothing() {
        XCTAssertEqual(FootnoteAnchors.find(in: ""), [])
        XCTAssertEqual(FootnoteAnchors.find(in: "Plain paragraph, no notes."), [])
        XCTAssertEqual(FootnoteAnchors.find(in: "[^"), [])
        XCTAssertEqual(FootnoteAnchors.find(in: "[^1]"), [])
    }

    // MARK: - Definition text

    func testADefinitionThatSpansIndentedLinesReadsAsOneNote() throws {
        let text = "Claim.[^1]\n\n[^1]: First line of the note\n    and the second line.\n    A third.\n\nNext paragraph."
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: text).first)
        XCTAssertEqual(anchor.text, "First line of the note and the second line. A third.")
        XCTAssertEqual(
            slice(text, anchor.definitionRange),
            "[^1]: First line of the note\n    and the second line.\n    A third.")
    }

    func testAnOrdinaryParagraphAfterAMidArticleDefinitionIsNotSwallowed() throws {
        let text = "Claim.[^1]\n\n[^1]: Short note.\n\nThis paragraph is body text.\n\n[^2]: Closing."
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: text).first)
        XCTAssertEqual(anchor.text, "Short note.")
    }

    func testInsideTheNotesSectionUnindentedLinesStillBelongToTheNote() throws {
        let body = "Claim.[^1] Other.[^2]\n\n"
        let notes = "[^1]: First line\ncontinues here.\n\n[^2]: Second."
        let anchors = FootnoteAnchors.find(in: body + notes, notesStartChar: body.count)
        XCTAssertEqual(anchors.map(\.text), ["First line continues here.", "Second."])
    }

    func testANotesSectionDefinitionEndsAtTheNextHeading() throws {
        let body = "Claim.[^1]\n\n"
        let notes = "[^1]: The note.\n\nMore Reading\n\nA list of books."
        let headingStart = body.count + "[^1]: The note.\n\n".count
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: body + notes, notesStartChar: body.count, headingStarts: [headingStart]).first)
        XCTAssertEqual(anchor.text, "The note.")
    }

    func testABackLinkArrowIsStrippedFromEitherEnd() {
        let text = "A.[^1] B.[^2] C.[^3]\n\n[^1]: ↩ Leading arrow.\n[^2]: Trailing arrow. ↩︎\n[^3]: ↑ Both. ↩\u{FE0E}"
        XCTAssertEqual(FootnoteAnchors.find(in: text).map(\.text), ["Leading arrow.", "Trailing arrow.", "Both."])
    }

    func testTheLabelWrittenAgainAheadOfTheWordsIsStripped() {
        let text = "A.[^3] B.[^b] C.[^c] D.[^d]\n\n[^3]: 3. Smith 2020.\n[^b]: b) Jones.\n[^c]: [^c] Lee.\n[^d]: 1984 was a novel."
        XCTAssertEqual(
            FootnoteAnchors.find(in: text).map(\.text),
            ["Smith 2020.", "Jones.", "Lee.", "1984 was a novel."])
    }

    func testANoteWhoseWordsAreEmptyAfterCleanupIsNotMatched() {
        let text = "A.[^1] B.[^2]\n\n[^1]: ↩\n[^2]: Real words."
        XCTAssertEqual(FootnoteAnchors.find(in: text).map(\.label), ["2"])
    }

    // MARK: - Unicode, whitespace and line breaks

    func testLabelsMatchAcrossUnicodeNormalizationForms() throws {
        let nfd = "e\u{0301}"
        let nfc = "\u{00E9}"
        let text = "Claim.[^\(nfd)]\n\n[^\(nfc)]: Café note."
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: text).first)
        XCTAssertEqual(anchor.label, nfc)
        XCTAssertEqual(anchor.text, "Café note.")
    }

    func testOffsetsCountCharactersNotUTF16Units() throws {
        let text = "Emoji 👩‍👩‍👧 and e\u{0301} here.[^1]\n\n[^1]: Note."
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: text).first)
        XCTAssertEqual(slice(text, anchor.citationRange), "[^1]")
        XCTAssertEqual(slice(text, anchor.definitionRange), "[^1]: Note.")
    }

    func testWindowsLineBreaksGiveTheSameNotes() throws {
        let unix = "Claim.[^1]\n\n[^1]: First line\n    second line."
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        let expected = try XCTUnwrap(FootnoteAnchors.find(in: unix).first)
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: windows).first)
        XCTAssertEqual(anchor.text, expected.text)
        XCTAssertEqual(slice(windows, anchor.citationRange), "[^1]")
    }

    func testTheDefinitionMustStartTheLine() {
        let text = "Claim.[^1]\n\n  [^1]: indented, so not a definition\nWords [^1]: also not a definition."
        XCTAssertEqual(FootnoteAnchors.find(in: text), [])
    }

    func testAColonAfterACitationInProseDoesNotMakeItADefinition() throws {
        let text = "See this[^1]: it matters.\n\n[^1]: The note."
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: text).first)
        XCTAssertEqual(slice(text, anchor.citationRange), "[^1]")
    }

    // MARK: - Stored text keeps no indentation

    func testAStoredDefinitionKeepsItsContinuationLineWithoutAnyNotesSection() throws {
        let markdown = "Claim.[^1]\n\n[^1]: First line\n    second line.\n\nNext paragraph."
        let parsed = try ObsidianMarkdownParser.parse(fileName: "one.md", contents: markdown)
        XCTAssertNil(parsed.notesStartChar, "one definition is not a closing notes run")
        let anchor = try XCTUnwrap(FootnoteAnchors.find(in: parsed.text, notesStartChar: parsed.notesStartChar).first)
        XCTAssertEqual(anchor.text, "First line second line.")
    }

    func testAContinuationLineThatCitesAnotherNoteIsNotThatNotesFirstCitation() {
        let text = "Body.[^1]\n\n[^1]: Note one\nsee also[^2]\n\n[^2]: Note two"
        let anchors = FootnoteAnchors.find(in: text)
        XCTAssertEqual(anchors.map(\.label), ["1"], "note 2 is cited only from inside note 1's words")
        XCTAssertEqual(anchors.first?.text, "Note one see also[^2]")
    }

    func testACitationAfterAMidArticleDefinitionAndBeforeTheNotesDoesNotCount() {
        let body = "Claim.[^1]\n\n[^1]: Mid note.\n\nMore body.[^1] And.[^2]\n\n"
        let text = body + "[^2]: Closing."
        let anchors = FootnoteAnchors.find(in: text, notesStartChar: body.count)
        XCTAssertEqual(anchors.map(\.label), ["1", "2"])
        XCTAssertEqual(anchors.first?.laterCitationRanges, [])
    }

    func testALabelRepeatedAsWordsOfTheNoteIsKept() {
        let text = "A.[^note] B.[^2]\n\n[^note]: note: remember the tide.\n[^2]: 2: 4 people attended."
        XCTAssertEqual(FootnoteAnchors.find(in: text).map(\.text), ["note: remember the tide.", "2: 4 people attended."])
    }

    // MARK: - Real stored text

    func testAnImportedMarkdownArticleFindsItsNotesAtTheirStoredOffsets() throws {
        let filler = Array(repeating: "A sentence of the body that stands between the notes.", count: 12).joined(separator: " ")
        let markdown = """
        ---
        title: Tides
        ---

        ## Setup

        The tide turns twice a day.[^1] \(filler)

        ## Argument

        Springs follow the moon.[^tides] \(filler) Neaps come between.[^1]

        [^1]: Smith, *Tides*, 2020.
        [^tides]: Jones, "The moon and the sea",
            Oceanography 12.
        [^3]: Nobody cites this one.
        """
        let parsed = try ObsidianMarkdownParser.parse(fileName: "tides.md", contents: markdown)
        let anchors = FootnoteAnchors.find(
            in: parsed.text, notesStartChar: parsed.notesStartChar, headingStarts: parsed.headings.map(\.startChar))

        XCTAssertEqual(anchors.map(\.label), ["1", "tides"])
        for anchor in anchors {
            XCTAssertEqual(slice(parsed.text, anchor.citationRange), "[^\(anchor.label)]")
            XCTAssertTrue(slice(parsed.text, anchor.definitionRange).hasPrefix("[^\(anchor.label)]:"))
        }
        XCTAssertEqual(anchors[0].text, "Smith, Tides, 2020.")
        XCTAssertEqual(anchors[0].laterCitationRanges.count, 1, "the second citation of note 1 is later and silent")
        XCTAssertTrue(anchors[1].text.hasPrefix("Jones,"), anchors[1].text)
        XCTAssertTrue(anchors[1].text.hasSuffix("Oceanography 12."), anchors[1].text)
        XCTAssertFalse(anchors.contains { $0.label == "3" })
    }

    // MARK: - Size

    func testAFootnoteHeavyArticleIsMatchedQuickly() throws {
        let body = (1...3000).map { "Claim \($0).[^\($0)] " }.joined() + "\n\n"
        let notes = (1...3000).map { "[^\($0)]: reference words" }.joined(separator: "\n\n")
        let text = body + notes
        XCTAssertGreaterThan(text.count, 50_000)

        let start = Date()
        let anchors = FootnoteAnchors.find(in: text, notesStartChar: body.count)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(anchors.count, 3000)
        XCTAssertEqual(anchors.map(\.label), (1...3000).map(String.init))
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.06 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards a rescan of the text per note.
        XCTAssertLessThan(elapsed, 2.0, "3000 notes in a debug build: one pass over the text, a loose ceiling that a per-note rescan would blow past")
    }
}
