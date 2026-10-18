import XCTest
@testable import SessionKit

/// #1579: stepping between chapters in the source-text reader, away from and back to the playing chapter.
final class PlaybackTextReaderBrowserTests: XCTestCase {
    private func article(chapterCount: Int = 4) -> (text: String, chapters: [Chapter]) {
        var text = ""
        var chapters: [Chapter] = []
        for number in 1...chapterCount {
            let start = text.count
            text += "Chapter \(number) heading.\n\nChapter \(number) first sentence. Chapter \(number) second sentence.\n\n"
            chapters.append(Chapter(id: "ch\(number)", title: "Chapter \(number)", startChar: start, endChar: text.count, percent: 0))
        }
        return (text, chapters)
    }

    private func browser(playingIn number: Int, chapters: [Chapter]? = nil, text: String? = nil) -> PlaybackTextReaderBrowser {
        let book = article()
        let chapters = chapters ?? book.chapters
        let text = text ?? book.text
        let offset = chapters.first { $0.id == "ch\(number)" }!.startChar + 2
        return PlaybackTextReaderBrowser(
            text: text, chapters: chapters,
            opening: PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, offset: offset))
    }

    func testStepsToNeighboursAndBackToTheSameOpeningTarget() {
        var reader = browser(playingIn: 2)
        let opening = reader.current
        XCTAssertEqual(opening.chapterTitle, "Chapter 2")
        XCTAssertNotNil(opening.sentence, "The opening chapter lights the sentence being read")
        reader.step(.next)
        XCTAssertEqual(reader.current.chapterTitle, "Chapter 3")
        XCTAssertNil(reader.current.sentence, "A chapter being browsed has no lit sentence")
        XCTAssertTrue(reader.current.text.hasPrefix("Chapter 3 heading."))
        XCTAssertFalse(reader.isAtOpening)
        reader.step(.previous)
        XCTAssertEqual(reader.current, opening, "Back at the first chapter, the sentence is lit again")
        XCTAssertTrue(reader.isAtOpening)
        reader.step(.previous)
        XCTAssertEqual(reader.current.chapterTitle, "Chapter 1")
        reader.returnToOpening()
        XCTAssertEqual(reader.current, opening)
    }

    func testEndsOfTheItemRefuseToStep() {
        var first = browser(playingIn: 1)
        XCTAssertFalse(first.canStep(.previous))
        XCTAssertTrue(first.canStep(.next))
        let before = first.current
        first.step(.previous)
        XCTAssertEqual(first.current, before)
        var last = browser(playingIn: 4)
        XCTAssertFalse(last.canStep(.next))
        XCTAssertTrue(last.canStep(.previous))
        last.step(.next)
        XCTAssertEqual(last.current.chapterTitle, "Chapter 4")
    }

    func testWalkingTheWholeItemVisitsEveryChapterOnceEachWay() {
        var reader = browser(playingIn: 1)
        var forward = [reader.position!.number]
        while reader.canStep(.next) { reader.step(.next); forward.append(reader.position!.number) }
        XCTAssertEqual(forward, [1, 2, 3, 4])
        XCTAssertEqual(reader.position?.count, 4)
        var backward = [reader.position!.number]
        while reader.canStep(.previous) { reader.step(.previous); backward.append(reader.position!.number) }
        XCTAssertEqual(backward, [4, 3, 2, 1])
    }

    func testStoredOrderDoesNotMatterAndEqualStartsShowOnce() {
        let book = article(chapterCount: 3)
        let c = book.chapters
        // Stored out of order, and chapter "dup" starts where ch2 does.
        let stored = [c[2], c[0], c[1], Chapter(id: "dup", title: "Dup", startChar: c[1].startChar, endChar: c[1].endChar, percent: 0)]
        var reader = browser(playingIn: 1, chapters: stored, text: book.text)
        XCTAssertEqual(reader.current.chapterTitle, "Chapter 1")
        reader.step(.next)
        XCTAssertEqual(reader.current.chapterTitle, "Dup", "Of chapters that share a start, the last stored is shown, as the opening rule picks")
        XCTAssertEqual(reader.position?.number, 2)
        XCTAssertEqual(reader.position?.count, 3)
        reader.step(.next)
        XCTAssertEqual(reader.current.chapterTitle, "Chapter 3")
        XCTAssertFalse(reader.canStep(.next))
        reader.step(.previous)
        XCTAssertEqual(reader.current.chapterTitle, "Dup")
        reader.step(.previous)
        XCTAssertEqual(reader.current.chapterTitle, "Chapter 1")
    }

    func testItemWithoutChaptersHasNothingToStepTo() {
        let text = "Only one passage. It has no chapters."
        var reader = PlaybackTextReaderBrowser(
            text: text, chapters: [], opening: PlaybackTextReaderTarget.resolve(text: text, chapters: [], offset: 3))
        XCTAssertFalse(reader.canStep(.next))
        XCTAssertFalse(reader.canStep(.previous))
        XCTAssertNil(reader.position)
        let before = reader.current
        reader.step(.next)
        XCTAssertEqual(reader.current, before)
        XCTAssertTrue(reader.isAtOpening)
    }

    func testSingleChapterAndChaptersPastTheEndOfTheText() {
        let book = article(chapterCount: 2)
        var chapters = book.chapters
        chapters.append(Chapter(id: "late", title: "Late", startChar: book.text.count + 500, endChar: book.text.count + 900, percent: 100))
        var reader = browser(playingIn: 2, chapters: chapters, text: book.text)
        XCTAssertTrue(reader.canStep(.next), "A stale start is clamped to the end, still after chapter 2")
        reader.step(.next)
        XCTAssertEqual(reader.current.chapterTitle, "Late")
        XCTAssertEqual(reader.current.text, "", "Nothing to show there, but the reader doesn't crash or skip")
        XCTAssertFalse(reader.canStep(.next))
        XCTAssertTrue(reader.canStep(.previous))
        var single = browser(playingIn: 1, chapters: [book.chapters[0]], text: book.text)
        XCTAssertFalse(single.canStep(.next))
        XCTAssertFalse(single.canStep(.previous))
        single.step(.next)
        XCTAssertEqual(single.position?.count, 1)
    }

    func testResolveByChapterIndexMatchesTheOpeningRuleAtTheChapterTop() {
        let book = article()
        for index in book.chapters.indices {
            let direct = PlaybackTextReaderTarget.resolve(text: book.text, chapters: book.chapters, chapterIndex: index)
            let atStart = PlaybackTextReaderTarget.resolve(
                text: book.text, chapters: book.chapters, offset: book.chapters[index].startChar)
            XCTAssertEqual(direct.chapterIndex, atStart.chapterIndex)
            XCTAssertEqual(direct.range, atStart.range)
            XCTAssertEqual(direct.text, atStart.text)
            XCTAssertNil(direct.sentence)
        }
        let outside = PlaybackTextReaderTarget.resolve(text: book.text, chapters: book.chapters, chapterIndex: 99)
        XCTAssertNil(outside.chapterIndex)
        XCTAssertEqual(outside.range, 0..<book.text.count)
    }

    func testSteppingBackToATiedOpeningChapterIsTheOpening() {
        let book = article(chapterCount: 3)
        let c = book.chapters
        // The playhead is unknown, so the reader opens at the named chapter: the first of two that share a start.
        let tied = [c[0], c[1], Chapter(id: "dup", title: "Dup", startChar: c[1].startChar, endChar: c[1].endChar, percent: 0), c[2]]
        let opening = PlaybackTextReaderTarget.resolve(text: book.text, chapters: tied, offset: nil, fallbackChapterId: "ch2")
        XCTAssertEqual(opening.chapterTitle, "Chapter 2")
        var reader = PlaybackTextReaderBrowser(text: book.text, chapters: tied, opening: opening)
        reader.step(.next)
        XCTAssertEqual(reader.current.chapterTitle, "Chapter 3")
        reader.step(.previous)
        XCTAssertEqual(reader.current, opening, "Back at the opening's start, the opening shows, not its tied twin")
        XCTAssertTrue(reader.isAtOpening, "So the way-back control goes away")
    }

    func testManyChaptersOverLongTextStaysQuick() {
        var text = ""
        var chapters: [Chapter] = []
        for number in 0..<400 {
            chapters.append(Chapter(id: "c\(number)", title: "C\(number)", startChar: text.count, endChar: text.count, percent: 0))
            text += String(repeating: "Wörds énd héré. ", count: 100)
        }
        let opening = PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, offset: 0)
        var reader = PlaybackTextReaderBrowser(text: text, chapters: chapters, opening: opening)
        let started = Date()
        for _ in 0..<200 {
            _ = reader.position
            _ = reader.canStep(.next)
            _ = reader.canStep(.previous)
            _ = reader.isAtOpening
        }
        reader.step(.next)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "Redraws must not recount the text per chapter")
        XCTAssertEqual(reader.position?.number, 2)
    }
}
