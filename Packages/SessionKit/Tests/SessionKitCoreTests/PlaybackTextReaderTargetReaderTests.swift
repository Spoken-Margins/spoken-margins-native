import Foundation
import XCTest
@testable import SessionKit

/// #1475: the redesign's reader opens through the same target as More > Text (#1547), so the UIKit reader must
/// light exactly the target's sentence, in UTF-16 units, including after emoji and accented text.
final class PlaybackTextReaderTargetReaderTests: XCTestCase {
    private let chapters = [
        Chapter(id: "c1", title: "One", startChar: 0, endChar: 40, percent: 0),
        Chapter(id: "c2", title: "Two", startChar: 40, endChar: 200, percent: 50),
    ]

    private func lit(_ text: String, offset: Int?) -> (title: String?, sentence: String?) {
        let reader = PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, offset: offset).reader
        let sentence = reader.currentSentenceRange.flatMap { Range($0, in: reader.text) }.map { String(reader.text[$0]) }
        return (reader.chapterTitle, sentence)
    }

    func testReaderLightsThePlayingChaptersSentence() throws {
        let text = "One.\n\nFirst sentence. Second sentence.\n\nTwo.\n\nThird sentence. Fourth sentence."
        let second = Chapter(id: "c2", title: "Two", startChar: characters(before: "Two.", in: text), endChar: text.count, percent: 50)
        let reader = PlaybackTextReaderTarget.resolve(
            text: text, chapters: [chapters[0], second], offset: characters(before: "Fourth", in: text)
        ).reader
        XCTAssertEqual(reader.chapterTitle, "Two")
        XCTAssertTrue(reader.text.hasPrefix("Two."))
        let range = try XCTUnwrap(reader.currentSentenceRange.flatMap { Range($0, in: reader.text) })
        XCTAssertEqual(String(reader.text[range]), "Fourth sentence.")
    }

    private func characters(before needle: String, in text: String) -> Int {
        text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound)
    }

    func testSentenceRangeIsInUTF16AfterEmojiAndAccents() {
        let text = "Café 👩‍👩‍👧 opens. Then this one."
        let result = lit(text, offset: characters(before: "Then", in: text))
        XCTAssertEqual(result.sentence, "Then this one.")
    }

    func testUnknownOffsetLightsNothing() {
        XCTAssertNil(lit("One sentence. Two sentences.", offset: nil).sentence)
    }

    func testEmptyTextHasNoRange() {
        let reader = PlaybackTextReaderTarget.resolve(text: "", chapters: [], offset: 0).reader
        XCTAssertEqual(reader.text, "")
        XCTAssertNil(reader.currentSentenceRange)
    }
}
