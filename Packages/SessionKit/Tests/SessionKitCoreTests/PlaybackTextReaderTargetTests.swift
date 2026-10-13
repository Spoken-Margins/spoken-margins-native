import XCTest
@testable import SessionKit

/// #1547: More > Text on the playback screen must open the playing chapter at the sentence being read.
final class PlaybackTextReaderTargetTests: XCTestCase {
    // Five chapters of an article, each "Title.\n\nSentence one. Sentence two.\n\n".
    private struct Book {
        let text: String
        let chapters: [Chapter]
    }

    private func article(chapterCount: Int = 5) -> Book {
        var text = ""
        var chapters: [Chapter] = []
        for number in 1...chapterCount {
            let start = text.count
            text += "Chapter \(number) heading.\n\nChapter \(number) first sentence. Chapter \(number) second sentence.\n\n"
            chapters.append(Chapter(id: "ch\(number)", title: "Chapter \(number)", startChar: start, endChar: text.count, percent: 0))
        }
        return Book(text: text, chapters: chapters)
    }

    private func offset(of needle: String, in text: String) -> Int {
        guard let range = text.range(of: needle) else {
            XCTFail("missing \(needle)")
            return 0
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private func sentence(_ target: PlaybackTextReaderTarget) -> String? {
        guard let range = target.sentence else { return nil }
        let characters = Array(target.text)
        return String(characters[range])
    }

    // MARK: The table

    func testArticleTable() {
        let book = article()
        let text = book.text
        let rows: [(name: String, offset: Int?, chapter: Int?, sentence: String?)] = [
            ("start of text", 0, 0, "Chapter 1 heading."),
            ("first chapter, mid sentence", offset(of: "1 second", in: text) + 4, 0, "Chapter 1 second sentence."),
            ("middle chapter", offset(of: "Chapter 3 first", in: text) + 12, 2, "Chapter 3 first sentence."),
            ("fourth chapter, the owner's case", offset(of: "Chapter 4 second", in: text), 3, "Chapter 4 second sentence."),
            ("last chapter", offset(of: "Chapter 5 second", in: text) + 3, 4, "Chapter 5 second sentence."),
            ("exactly at a chapter boundary", book.chapters[1].startChar, 1, "Chapter 2 heading."),
            ("one before a chapter boundary", book.chapters[1].startChar - 1, 0, "Chapter 1 second sentence."),
            ("end of text", text.count, 4, "Chapter 5 second sentence."),
            ("past the end", text.count + 500, 4, "Chapter 5 second sentence."),
            ("unknown offset", nil, 0, nil),
            ("offset -1", -1, 0, nil)
        ]
        for row in rows {
            let target = PlaybackTextReaderTarget.resolve(text: text, chapters: book.chapters, offset: row.offset)
            XCTAssertEqual(target.chapterIndex, row.chapter, row.name)
            XCTAssertEqual(target.chapterTitle, row.chapter.map { "Chapter \($0 + 1)" }, row.name)
            XCTAssertEqual(sentence(target), row.sentence, row.name)
            if let chapter = row.chapter {
                XCTAssertTrue(target.text.hasPrefix("Chapter \(chapter + 1) heading."), row.name)
                XCTAssertTrue(target.text.hasSuffix("Chapter \(chapter + 1) second sentence."), row.name)
            }
        }
    }

    func testUnknownOffsetOpensTheSessionChapterAtItsTop() {
        let book = article()
        for offset in [nil, -1, -40] as [Int?] {
            let target = PlaybackTextReaderTarget.resolve(text: book.text, chapters: book.chapters, offset: offset, fallbackChapterId: "ch4")
            XCTAssertEqual(target.chapterIndex, 3, "offset \(String(describing: offset))")
            XCTAssertNil(target.sentence)
        }
        let unknownId = PlaybackTextReaderTarget.resolve(text: book.text, chapters: book.chapters, offset: nil, fallbackChapterId: "gone")
        XCTAssertEqual(unknownId.chapterIndex, 0)
        // A known playhead wins over the session's chapter.
        let known = PlaybackTextReaderTarget.resolve(text: book.text, chapters: book.chapters, offset: book.chapters[1].startChar, fallbackChapterId: "ch4")
        XCTAssertEqual(known.chapterIndex, 1)
    }

    func testNoChaptersShowsTheWholeTextAtTheSentence() {
        let text = "  First sentence here. Second one is read now. Third.  "
        let target = PlaybackTextReaderTarget.resolve(text: text, chapters: [], offset: offset(of: "one is", in: text))
        XCTAssertNil(target.chapterIndex)
        XCTAssertNil(target.chapterTitle)
        XCTAssertEqual(target.range, 0..<text.count)
        XCTAssertEqual(target.text, "First sentence here. Second one is read now. Third.")
        XCTAssertEqual(sentence(target), "Second one is read now.")
        XCTAssertNil(PlaybackTextReaderTarget.resolve(text: text, chapters: [], offset: nil).sentence)
    }

    func testEmptyTextHasNothingToLight() {
        for chapters in [[], [Chapter(id: "a", title: "A", startChar: 0, endChar: 0, percent: 0)]] {
            let target = PlaybackTextReaderTarget.resolve(text: "", chapters: chapters, offset: 12)
            XCTAssertEqual(target.text, "")
            XCTAssertNil(target.sentence)
            XCTAssertEqual(target.range, 0..<0)
        }
    }

    func testOffsetBeforeTheFirstChapterOpensTheFirstChapter() {
        let text = "Read by the app first. Opening chapter text. Second chapter text."
        let opening = offset(of: "Opening", in: text)
        let second = offset(of: "Second", in: text)
        let chapters = [
            Chapter(id: "a", title: "Opening", startChar: opening, endChar: second, percent: 0),
            Chapter(id: "b", title: "Second", startChar: second, endChar: text.count, percent: 0)
        ]
        let target = PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, offset: 3)
        XCTAssertEqual(target.chapterIndex, 0)
        XCTAssertEqual(sentence(target), "Opening chapter text.")
    }

    // MARK: PDFs and maps whose stored ranges don't tile the text

    /// A PDF outline whose first entry is the whole document (a title or "Part One" node spanning every page),
    /// followed by the real chapters. The playback header names the playing chapter; the reader must too.
    func testOutlineEntrySpanningTheDocumentDoesNotHideThePlayingChapter() {
        let book = article()
        var chapters = book.chapters
        chapters[0].endChar = book.text.count
        let target = PlaybackTextReaderTarget.resolve(
            text: book.text, chapters: chapters, offset: offset(of: "Chapter 4 second", in: book.text)
        )
        XCTAssertEqual(target.chapterIndex, 3)
        XCTAssertEqual(sentence(target), "Chapter 4 second sentence.")
        XCTAssertFalse(target.text.contains("Chapter 5"))
    }

    /// Stored ends that are stale (zero) or stop short of the next chapter, as hard-wrapped PDF text with page
    /// breaks between chapters produces.
    func testPDFChaptersWithGapsAndStaleEnds() {
        let text = "Cover page\u{000C}Methods\nWe measured the\nsamples twice. Then we\nwaited.\u{000C}Page 7\u{000C}Results\nThe effect\nwas small. It held.\n"
        let methods = offset(of: "Methods", in: text)
        let results = offset(of: "Results", in: text)
        let chapters = [
            Chapter(id: "m", title: "Methods", startChar: methods, endChar: offset(of: "\u{000C}Page 7", in: text), percent: 0),
            Chapter(id: "r", title: "Results", startChar: results, endChar: 0, percent: 0)
        ]
        let rows: [(name: String, offset: Int, chapter: Int, sentence: String)] = [
            ("hard-wrapped sentence", offset(of: "samples", in: text), 0, "We measured the\nsamples twice."),
            ("gap between chapters", offset(of: "Page 7", in: text), 0, "Page 7"),
            ("chapter with a stale end", offset(of: "It held", in: text), 1, "It held.")
        ]
        for row in rows {
            let target = PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, offset: row.offset)
            XCTAssertEqual(target.chapterIndex, row.chapter, row.name)
            XCTAssertNotNil(sentence(target), row.name)
            XCTAssertTrue(sentence(target)?.contains(row.sentence) == true, "\(row.name): \(String(describing: sentence(target)))")
        }
    }

    func testUnsortedAndDuplicateChapterStarts() {
        let book = article(chapterCount: 3)
        let shuffled = [book.chapters[2], book.chapters[0], book.chapters[1]]
        let target = PlaybackTextReaderTarget.resolve(text: book.text, chapters: shuffled, offset: offset(of: "Chapter 2 first", in: book.text))
        XCTAssertEqual(target.chapterIndex, 2, "index into the array as passed")
        XCTAssertEqual(target.chapterTitle, "Chapter 2")

        var duplicate = book.chapters[1]
        duplicate.id = "dup"
        duplicate.title = "Chapter 2 again"
        let withDuplicate = PlaybackTextReaderTarget.resolve(
            text: book.text, chapters: book.chapters + [duplicate], offset: offset(of: "Chapter 2 first", in: book.text)
        )
        XCTAssertEqual(withDuplicate.chapterTitle, "Chapter 2 again", "the later entry at the same start wins, as in the header")
        XCTAssertTrue(withDuplicate.text.hasSuffix("Chapter 2 second sentence."))
    }

    func testOffsetsCountCharactersNotUTF16() {
        let text = "Intro 👩🏽‍🔬 é.\n\nCafé ﬁrst 🇨🇦 line. Second café line."
        let second = offset(of: "Café", in: text)
        let chapters = [
            Chapter(id: "a", title: "Intro", startChar: 0, endChar: second, percent: 0),
            Chapter(id: "b", title: "Café", startChar: second, endChar: text.count, percent: 0)
        ]
        let target = PlaybackTextReaderTarget.resolve(text: text, chapters: chapters, offset: offset(of: "Second café", in: text))
        XCTAssertEqual(target.chapterIndex, 1)
        XCTAssertEqual(sentence(target), "Second café line.")
    }

    /// The reader names the same chapter the playback header shows, for every playhead in the text.
    func testAgreesWithThePlaybackHeaderAtEveryOffset() {
        let book = article()
        var chapters = book.chapters
        chapters[0].endChar = book.text.count // the overlapping outline case
        var context = PlaybackChapterContext(
            snapshot: SessionSnapshot(), id: "item", title: "Article",
            chapters: chapters, mediaChapters: [], listeningMapScenes: [],
            turns: [], sessionItemId: nil, sessionChapterId: nil
        )
        context.snapshot.targetType = TargetType.itemTextTTS.rawValue
        for playhead in stride(from: -1, through: book.text.count + 1, by: 1) {
            context.snapshot.currentTextStart = playhead
            let header = PlaybackChapterLocator.currentChapter(context)?.id
            let target = PlaybackTextReaderTarget.resolve(text: book.text, chapters: chapters, offset: playhead)
            XCTAssertEqual(target.chapterIndex.map { chapters[$0].id }, header, "offset \(playhead)")
        }
    }
}
