import Foundation
import XCTest
@testable import SessionKit

final class PlaybackTextPeekTests: XCTestCase {
    private let parts = (1...4).map {
        "Chapter \($0) begins. The sentence being read in chapter \($0). Chapter \($0) ends.\n\n"
    }

    private var book: (text: String, chapters: [Chapter]) {
        var start = 0
        let chapters = parts.enumerated().map { index, text in
            defer { start += text.count }
            return Chapter(id: "c\(index + 1)", title: "Chapter \(index + 1)",
                           startChar: start, endChar: start + text.count, percent: index * 25)
        }
        return (parts.joined(), chapters)
    }

    func testChapterFourOpensAtSentenceBeingReadWithWholeChapterAvailable() throws {
        let (text, chapters) = book
        let sentence = "The sentence being read in chapter 4."
        let range = try XCTUnwrap(text.range(of: sentence))
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let peek = PlaybackTextPeek(title: "Book", text: text, chapters: chapters, offset: start + 10)
        XCTAssertEqual(peek.chapterTitle, "Chapter 4")
        XCTAssertEqual(peek.passage.sentences.map(\.text), ["Chapter 4 begins.", sentence, "Chapter 4 ends."])
        XCTAssertEqual(peek.initialSentenceID, start)
        XCTAssertEqual(peek.passage.sentences.first(where: \.isCurrent)?.text, sentence)
        XCTAssertFalse(peek.passage.hasEarlier)
        XCTAssertFalse(peek.passage.hasLater)
    }

    func testEveryChapterAndBoundaryUsesSourceCharacterOffset() {
        let (text, chapters) = book
        for chapter in chapters {
            for offset in [chapter.startChar, chapter.startChar + 5, chapter.endChar - 1] {
                let peek = PlaybackTextPeek(title: "Book", text: text, chapters: chapters, offset: offset)
                XCTAssertEqual(peek.chapterTitle, chapter.title, "offset \(offset)")
                XCTAssertNotNil(peek.initialSentenceID)
                XCTAssertTrue(peek.passage.sentences.allSatisfy {
                    $0.start >= chapter.startChar && $0.end <= chapter.endChar
                })
            }
        }
        for (offset, expected) in [(-10, "Chapter 1"), (text.count, "Chapter 4"), (text.count + 10, "Chapter 4")] {
            XCTAssertEqual(PlaybackTextPeek(title: "Book", text: text, chapters: chapters, offset: offset).chapterTitle, expected)
        }
    }

    func testUnicodeAndUnchapteredTextUseTheSameSentenceIDsAsPlayback() throws {
        let text = "Family 👨‍👩‍👧. Cafe\u{301} opens. Final sentence."
        let range = try XCTUnwrap(text.range(of: "Final"))
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let peek = PlaybackTextPeek(title: "Article", text: text, chapters: [], offset: start + 4)
        XCTAssertEqual(peek.chapterTitle, "Full Text")
        XCTAssertEqual(peek.initialSentenceID, start)
        XCTAssertEqual(peek.passage.sentences.count, 3)
        XCTAssertEqual(peek.passage.sentences.last?.text, "Final sentence.")
    }

    func testEmptyTextHasNoScrollTarget() {
        for text in ["", " \n\t "] {
            let peek = PlaybackTextPeek(title: "Empty", text: text, chapters: [], offset: 20)
            XCTAssertTrue(peek.passage.sentences.isEmpty)
            XCTAssertNil(peek.initialSentenceID)
        }
    }

    func testReopeningCapturesNewPositionWithoutChangingPreviousPresentation() {
        let (text, chapters) = book
        let first = PlaybackTextPeek(title: "Book", text: text, chapters: chapters, offset: 0)
        let later = PlaybackTextPeek(title: "Book", text: text, chapters: chapters, offset: chapters[3].startChar)
        XCTAssertNotEqual(first.id, later.id)
        XCTAssertEqual(first.chapterTitle, "Chapter 1")
        XCTAssertEqual(later.chapterTitle, "Chapter 4")
        XCTAssertEqual(first.initialSentenceID, 0)
        XCTAssertEqual(later.initialSentenceID, chapters[3].startChar)
    }

    // SwiftUI cannot run in the host suite. Guard the presentation boundary as
    // well as testing the real content/scroll-target resolver below: a correct
    // resolver alone would not catch the old separate offset and sheet flag.
    func testPlaybackPresentsCapturedTextAfterMoreDismissesAndScrollsToSentence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackScreen.swift"
        ), encoding: .utf8)
        XCTAssertFalse(source.contains("sourceTextOffsetAtPresentation"),
                       "A separate offset can be stale when the boolean sheet opens")
        XCTAssertTrue(source.contains(".sheet(item: $sourceTextPresentation)"),
                      "The sheet must receive the captured playhead with its content")
        XCTAssertTrue(source.contains("NativeTextPeekView(presentation: presentation)"))
        XCTAssertTrue(source.contains("offset: model.snapshot.currentTextStart ?? 0"),
                      "Capture the canonical source offset at the Text tap")
        XCTAssertTrue(source.contains("closeOptions(to: .text(presentation))"),
                      "Dismiss More before presenting its Text destination")
        XCTAssertTrue(source.contains("case .text(let presentation): sourceTextPresentation = presentation"))
        XCTAssertTrue(source.contains("proxy.scrollTo(sentenceID, anchor: .top)"),
                      "The reader must scroll to the resolved current sentence")
        XCTAssertTrue(source.contains("sentenceID = presentation.initialSentenceID"))
        XCTAssertTrue(source.contains(".id(sentence.id)"))
    }
}
