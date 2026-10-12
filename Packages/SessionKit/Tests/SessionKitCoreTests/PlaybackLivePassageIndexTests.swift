import Foundation
import XCTest
@testable import SessionKit

final class PlaybackLivePassageIndexTests: XCTestCase {
    private typealias Passage = PlaybackLivePassage

    func testTicksAndBackwardSeeksReuseTheParsedChapterButUpdateTheLitSentence() throws {
        var index = Passage.Index(text: "One. Two. Three. Four. Five. Six.")
        XCTAssertTrue(index.update(offset: 6))
        let chapter = try XCTUnwrap(index.chapter)
        for offset in [7, 8, 9] {
            XCTAssertFalse(index.update(offset: offset))
            XCTAssertTrue(index.chapter === chapter)
            XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.text, "Two.")
        }
        XCTAssertTrue(index.update(offset: 30))
        XCTAssertEqual(index.window.sentences.map(\.text), ["Five.", "Six."])
        XCTAssertTrue(index.update(offset: 0))
        XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.text, "One.")
        XCTAssertTrue(index.chapter === chapter)
    }

    func testSeparatorWhitespaceAndEOFKeepTheirSentenceOwnership() throws {
        var index = Passage.Index(text: "  One.\n \n  Two.  Three.\n")
        index.update(offset: 2)
        let chapter = try XCTUnwrap(index.chapter)
        for offset in [0, 5, 6, 8, 10] {
            XCTAssertFalse(index.update(offset: offset))
            XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.start, 2)
        }
        XCTAssertTrue(index.update(offset: 11))
        XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.text, "Two.")
        XCTAssertFalse(index.update(offset: 16))
        XCTAssertTrue(index.update(offset: 24))
        XCTAssertEqual(index.window.sentences.last?.text, "Three.")
        XCTAssertTrue(index.chapter === chapter)
    }

    func testChangedMarginsRefreshDiamondsWithoutMovingOrReparsing() throws {
        var index = Passage.Index(text: "One. Two. Three.")
        index.update(offset: 6)
        let chapter = try XCTUnwrap(index.chapter)
        let margins: [Passage.Margin] = [.init(id: "own", offset: 8, origin: .own), .init(id: "shared", offset: 9, origin: .shared)]
        XCTAssertTrue(index.update(offset: 6, margins: margins))
        XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.diamonds.map(\.id), ["own", "shared"])
        XCTAssertFalse(index.update(offset: 7, margins: margins))
        XCTAssertTrue(index.update(offset: 7, margins: []))
        XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.diamonds, [])
        XCTAssertTrue(index.chapter === chapter)
    }

    func testChapterGapAndRevisitUseTheReaderChapterRuleAndReuseTheCache() throws {
        let text = "One. Two.   Three. Four."
        let chapters = [Chapter(id: "a", title: "First", startChar: 0, endChar: 9, percent: 0),
                        Chapter(id: "b", title: "Second", startChar: 12, endChar: text.count, percent: 50)]
        var index = Passage.Index(text: text, chapters: chapters)
        index.update(offset: 0)
        let first = try XCTUnwrap(index.chapter)
        index.update(offset: 10)
        XCTAssertTrue(index.chapter === first)
        XCTAssertEqual(index.window.sentences.first(where: \.isCurrent)?.text, "Two.")
        index.update(offset: 12)
        XCTAssertFalse(index.chapter === first)
        XCTAssertEqual(index.window.chapterTitle, "Second")
        index.update(offset: 0)
        XCTAssertTrue(index.chapter === first)
        var replacement = Passage.Index(text: "Changed.", chapters: [])
        replacement.update(offset: 0)
        XCTAssertFalse(replacement.chapter === first)
        XCTAssertEqual(replacement.window.sentences.map(\.text), ["Changed."])
    }

    func testReaderKeepsTheWholeChapterAndConvertsGraphemesToUTF16() throws {
        let text = "Outside.   One 👨‍👩‍👧‍👦.  Café e\u{301}!\r\nTail.  After."
        let chars = Array(text)
        let start = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "   One")).lowerBound)
        let end = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "After")).lowerBound)
        let current = text.distance(from: text.startIndex, to: try XCTUnwrap(text.range(of: "Café")).lowerBound)
        var index = Passage.Index(text: text, chapters: [.init(id: "c", title: "Chapter", startChar: start, endChar: end, percent: 0)])
        index.update(offset: current)
        let reader = try XCTUnwrap(index.chapter).reader(at: current)
        XCTAssertEqual(reader.chapterTitle, "Chapter")
        XCTAssertEqual(reader.text, String(chars[start..<end]), "Keep leading, intervening and trailing whitespace for continuous selection")
        let range = try XCTUnwrap(reader.currentSentenceRange)
        XCTAssertEqual((reader.text as NSString).substring(with: range), "Café e\u{301}!")
        XCTAssertGreaterThan(range.location, current - start, "Emoji consumes more UTF-16 units than Characters")
        XCTAssertTrue(reader.text.hasSuffix("Tail.  "))
    }
}
