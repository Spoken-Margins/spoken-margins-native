import XCTest
@testable import SessionKit

/// The rule-based chapters (#2256) moved out of `SessionEngine` so they can run off the main thread. These tables pin
/// what they have always produced, with neighbouring texts: empty, one sentence, no end punctuation, spaces and
/// newlines after the full stop, Unicode, and a text long enough to hit the chapter limits.
final class GeneratedListeningMapTests: XCTestCase {
    private func item(_ text: String?, title: String = "Notes") -> Item {
        Item(id: "item-1", title: title, mediaType: "text", text: text, externalReference: nil, status: "needs_listening_map")
    }

    private func map(_ text: String) -> ListeningMap {
        GeneratedListeningMap.make(for: item(text), text: GeneratedListeningMap.text(for: item(text), transcript: nil))
    }

    func testEmptyAndBlankTextIsOneChapterNamedByNumber() {
        for text in ["", "   \n\t "] {
            let made = map(text)
            XCTAssertEqual(made.chapters.map(\.title), ["Chapter 1"], "text: \(text.debugDescription)")
            XCTAssertEqual(made.chapters.map(\.startChar), [0])
            XCTAssertEqual(made.chapters.map(\.percent), [0])
        }
    }

    func testShortTextHasOneChapterPerSentenceTitledByItsFirstWords() {
        let made = map("The first sentence is here. A second one follows it closely, with a long tail of words. Third!")
        XCTAssertEqual(made.chapters.map(\.title), ["The first sentence is here", "A second one follows it closely,", "Third"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:,")) })
        XCTAssertEqual(made.chapters.map(\.id), ["ch-generated-01", "ch-generated-02", "ch-generated-03"])
        XCTAssertEqual(made.chapters.first?.startChar, 0)
        XCTAssertEqual(made.chapters.last?.endChar, "The first sentence is here. A second one follows it closely, with a long tail of words. Third!".count)
        XCTAssertEqual(made.id, "map-item-1-generated")
    }

    func testTextWithNoEndPunctuationIsOneChapter() {
        let made = map("one long run of words with no full stop at all")
        XCTAssertEqual(made.chapters.count, 1)
        XCTAssertEqual(made.chapters[0].title, "one long run of words with")
    }

    func testNewlinesAndSpacesAfterAFullStopAreConsumedBeforeTheNextChapter() {
        let text = "Alpha one.\n\n  Beta two.   Gamma three."
        let starts = GeneratedListeningMap.chapterStarts(for: text)
        XCTAssertEqual(starts, [0, 14, 26])
        XCTAssertEqual(map(text).chapters.map(\.title), ["Alpha one", "Beta two", "Gamma three"])
    }

    func testAFullStopAtTheVeryEndStartsNothingNew() {
        XCTAssertEqual(GeneratedListeningMap.chapterStarts(for: "Only one."), [0])
    }

    func testUnicodeIsCountedInCharactersNotBytes() {
        let text = "Café crème, déjà vu. 日本語の文です。 Third part here."
        let starts = GeneratedListeningMap.chapterStarts(for: text)
        XCTAssertEqual(starts, [0, 21])
        let made = map(text)
        XCTAssertEqual(made.chapters.map(\.startChar), starts)
        XCTAssertEqual(made.chapters.last?.endChar, text.count)
    }

    func testALongTextGetsOneChapterPerAbout900CharactersFromFiveToTwelve() {
        func sentences(_ count: Int) -> String {
            (1...count).map { "This is sentence number \($0) of a long enough article to need several chapters." }.joined(separator: " ")
        }
        // 80 sentences is about 6,500 characters: 8 sentences or fewer is cut per sentence; above it, in even strides.
        let text = sentences(80)
        let starts = GeneratedListeningMap.chapterStarts(for: text)
        XCTAssertEqual(starts.count, 7)
        XCTAssertEqual(starts.first, 0)
        let chars = Array(text)
        for start in starts.dropFirst() {
            XCTAssertEqual(chars[start - 1], " ", "every chapter after the first starts just after a sentence")
            XCTAssertFalse(chars[start].isWhitespace)
        }
        XCTAssertEqual(starts, starts.sorted())
        let made = map(text)
        XCTAssertEqual(made.chapters.map(\.percent), made.chapters.map(\.percent).sorted())
        XCTAssertEqual(made.chapters.map(\.endChar), Array(starts.dropFirst()) + [text.count])
        // Twelve at most, however long.
        XCTAssertEqual(GeneratedListeningMap.chapterStarts(for: sentences(2_000)).count, 12)
    }

    func testTheTextOfAnItemWithNoOwnTextIsItsTranscriptInTimeOrder() {
        let transcript = TranscriptTimeline(segments: [
            MediaTimelineSegment(id: "b", startMs: 5_000, endMs: 9_000, startChar: 0, endChar: 0, text: "later"),
            MediaTimelineSegment(id: "a", startMs: 0, endMs: 5_000, startChar: 0, endChar: 0, text: "sooner"),
        ], chapters: [], durationMs: 9_000)
        XCTAssertEqual(GeneratedListeningMap.text(for: item(nil), transcript: transcript), "sooner later")
        XCTAssertEqual(GeneratedListeningMap.text(for: item("   "), transcript: transcript), "sooner later", "blank text counts as none")
        XCTAssertEqual(GeneratedListeningMap.text(for: item("own text"), transcript: transcript), "own text")
        XCTAssertEqual(GeneratedListeningMap.text(for: item(nil), transcript: nil), "")
    }
}
