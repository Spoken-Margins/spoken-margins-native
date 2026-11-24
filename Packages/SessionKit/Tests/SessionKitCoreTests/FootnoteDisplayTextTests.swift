import Foundation
import XCTest
@testable import SessionKit

/// #5109: Now's reader showed a Markdown file's footnotes as raw syntax ("twice a day.[^1]", "[^1]: Smith, …"). The
/// shown text now writes them as a listener reads them, while the stored text, its offsets and the spoken text stay.
final class FootnoteDisplayTextTests: XCTestCase {
    /// The Test Desk's "Tides with notes.md", as the import stores it.
    private let tides = """
    The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Jones, Harbour Life, page 12.
    """

    private func shown(_ text: String) -> String {
        FootnoteDisplayText(text: text).render(text, from: 0)
    }

    // MARK: - The neighbouring inputs

    func testACitedAndDefinedNoteShowsAsARaisedNumberAndItsDefinitionAsAFootnote() {
        XCTAssertEqual(shown(tides), """
        The tide turns twice a day.¹ It rests between turns. Boats wait for it.² Then they leave.

        Footnote 1: Smith, Tides, 2020.
        Footnote 2: Jones, Harbour Life, page 12.
        """)
    }

    func testAMarkerWithNoDefinitionIsLeftAsItIs() {
        let text = "A claim.[^1] Another.[^9]\n\n[^1]: Defined."
        XCTAssertEqual(shown(text), "A claim.¹ Another.[^9]\n\nFootnote 1: Defined.")
        XCTAssertEqual(shown("A claim.[^1] No definition anywhere."), "A claim.[^1] No definition anywhere.")
        XCTAssertTrue(FootnoteDisplayText(text: "Plain prose, no notes.").isEmpty)
    }

    func testTwoCitationsInOneSentence() {
        let text = "Both agree.[^1][^2] And more.[^10]\n\n[^1]: One.\n[^2]: Two.\n[^10]: Ten."
        XCTAssertEqual(shown(text), "Both agree.¹² And more.¹⁰\n\nFootnote 1: One.\nFootnote 2: Two.\nFootnote 10: Ten.")
    }

    func testADefinitionBlockAtTheEndAndAWordLabel() {
        let text = "Cited here.[^note-a] Later.[^b]\n\nNotes\n\n[^note-a]: A long note\n  that continues.\n[^b]: Short."
        XCTAssertEqual(shown(text),
                       "Cited here.[note-a] Later.[b]\n\nNotes\n\nFootnote note-a: A long note\n  that continues.\nFootnote b: Short.")
    }

    func testANoteCitedInsideAnotherNoteAndADefinitionNobodyCites() {
        let text = "Body.[^1]\n\n[^1]: See also[^2].\n[^2]: Nobody cites me in the body."
        XCTAssertEqual(shown(text), "Body.¹\n\nFootnote 1: See also².\nFootnote 2: Nobody cites me in the body.")
    }

    func testMarkersInAFencedBlockAndLookalikesStay() {
        let text = "Real.[^1] Not one: [^ 1], [1], ^1, [^].\n\n```\ncode[^1]\n[^1]: in code\n```\n\n[^1]: Real note."
        XCTAssertEqual(shown(text),
                       "Real.¹ Not one: [^ 1], [1], ^1, [^].\n\n```\ncode[^1]\n[^1]: in code\n```\n\nFootnote 1: Real note.")
    }

    func testUnicodeLabelsMatchInCanonicalForm() {
        // "é" precomposed in the citation, decomposed in the definition: one label.
        let text = "Café.[^caf\u{E9}]\n\n[^cafe\u{301}]: Note."
        let result = shown(text)
        XCTAssertEqual(result, "Café.[caf\u{E9}]\n\nFootnote caf\u{E9}: Note.")
        // String == ignores the form, so pin it: both labels show in the one canonical (precomposed) form.
        XCTAssertEqual(Array(result.unicodeScalars).filter { $0 == "\u{301}" }.count, 0)
    }

    // MARK: - Slices, offsets and the lit sentence

    func testASliceRendersAtItsOwnOffsetAndHalfAMarkerStaysAsStored() {
        let display = FootnoteDisplayText(text: tides)
        let characters = Array(tides)
        let cite = tides.distance(from: tides.startIndex, to: tides.range(of: "[^1]")!.lowerBound)
        // The citing sentence alone, as a Now row cuts it.
        let sentence = String(characters[0..<(cite + 4)])
        XCTAssertEqual(display.render(sentence, from: 0), "The tide turns twice a day.¹")
        // A slice that stops inside the marker.
        let half = String(characters[0..<(cite + 2)])
        XCTAssertEqual(display.render(half, from: 0), half)
        // A slice from later in the text uses its own offset.
        let later = String(characters[cite...])
        XCTAssertTrue(display.render(later, from: cite).hasPrefix("¹ It rests"))
    }

    func testNowRowFragmentsShowTheMarkersButKeepStoredOffsets() {
        var index = PlaybackLivePassage.Index(text: tides, chapters: [])
        _ = index.updateScene(offset: 0, margins: [])
        let source = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: tides), footnotes: FootnoteDisplayText(text: tides))
        let rows = index.scene.sentences
        XCTAssertFalse(rows.isEmpty)
        let shown = rows.map { source.fragments(for: $0).map(\.text).joined() }
        XCTAssertFalse(shown.joined().contains("[^"), "\(shown)")
        // The sentence splitter reads ".[^1] It" as one run, as it did before; only the marker's look changes.
        XCTAssertEqual(shown.first, "The tide turns twice a day.¹ It rests between turns.")
        for row in rows {
            XCTAssertEqual(source.fragments(for: row).first?.start, row.start, "a fragment's start stays a stored offset")
        }
        // The stored rows themselves are unchanged, so Margins and the playhead land where they did.
        XCTAssertEqual(rows.first?.text, "The tide turns twice a day.[^1] It rests between turns.")
        // Without footnotes the index shows the stored text, as before.
        let plain = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: tides))
        XCTAssertEqual(plain.fragments(for: rows[0]).map(\.text).joined(), rows[0].text)
    }

    func testTheReaderSheetShowsTheMarkersAndLightsTheSameWords() throws {
        let offset = tides.distance(from: tides.startIndex, to: tides.range(of: "Boats")!.lowerBound)
        let target = PlaybackTextReaderTarget.resolve(text: "\n\n" + tides, chapters: [], offset: offset + 2)
        XCTAssertEqual(target.textStart, 2)
        let browser = PlaybackTextReaderBrowser(text: "\n\n" + tides, chapters: [], opening: target)
        let reader = browser.reader
        XCTAssertFalse(reader.text.contains("[^"))
        XCTAssertTrue(reader.text.contains("Footnote 2: Jones, Harbour Life, page 12."))
        let range = try XCTUnwrap(reader.currentSentenceRange)
        XCTAssertEqual((reader.text as NSString).substring(with: range), "Boats wait for it.² Then they leave.")
        // The plain reader is as it was.
        XCTAssertEqual(target.reader.text, target.text)
    }

    func testARangeEndingInsideAMarkerCoversItsReplacement() {
        let display = FootnoteDisplayText(text: tides)
        let cite = tides.distance(from: tides.startIndex, to: tides.range(of: "[^1]")!.lowerBound)
        let moved = display.render(tides, from: 0, keeping: (cite - 4)..<(cite + 2))
        XCTAssertEqual(moved.range, (cite - 4)..<(cite + 1))
        let after = display.render(tides, from: 0, keeping: (cite + 5)..<(cite + 7))
        XCTAssertEqual(String(Array(after.text)[after.range!]), "It")
    }

    // MARK: - What is heard

    func testTheSpokenTextHasNoMarkerSyntax() {
        for asides in [false, true] {
            let plan = NarrationChunkPlanner.articlePlan(tides, asides: asides)
            let spoken = plan.chunks.map(\.text).joined(separator: " ") + plan.normalizedText
            XCTAssertFalse(spoken.contains("[^"), "asides \(asides)")
            XCTAssertFalse(spoken.contains("^"), "asides \(asides)")
        }
        XCTAssertFalse(SpeechTextNormalizer.projectForSystemSpeech(tides).text.contains("^"))
    }
}
