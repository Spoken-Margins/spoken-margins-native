import Foundation
import XCTest
@testable import SessionKit

/// The Now view's live passage on an article or PDF: which sentences show for a playhead offset, which one is lit,
/// and where each Margin's diamond falls (#451).
final class PlaybackLivePassageTests: XCTestCase {
    private typealias Passage = PlaybackLivePassage

    private let six = "One. Two. Three. Four. Five. Six."

    /// The Character offset where `needle` first starts in `text`.
    private func offset(of needle: String, in text: String) -> Int {
        guard let range = text.range(of: needle) else {
            XCTFail("\(needle) not in text")
            return 0
        }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    private func texts(_ window: Passage.Window) -> [String] { window.sentences.map(\.text) }

    private func passage(
        _ text: String,
        at needle: String,
        chapters: [Chapter] = [],
        margins: [Passage.Margin] = [],
        before: Int = Passage.defaultSentencesBefore,
        after: Int = Passage.defaultSentencesAfter
    ) -> Passage.Window {
        Passage.window(text: text, chapters: chapters, offset: offset(of: needle, in: text), margins: margins,
                       sentencesBefore: before, sentencesAfter: after)
    }

    private func chapter(_ id: String, _ title: String, in text: String, from start: String, to end: String?) -> Chapter {
        Chapter(id: id, title: title, startChar: offset(of: start, in: text),
                endChar: end.map { offset(of: $0, in: text) } ?? text.count, percent: 0)
    }

    // MARK: Which sentences

    func testNoTextShowsNothing() {
        XCTAssertEqual(Passage.window(text: "", offset: 0), .empty)
        XCTAssertEqual(Passage.window(text: "", offset: 40, margins: [.init(id: "m", offset: 3, origin: .own)]), .empty)
    }

    func testWhitespaceOnlyTextShowsNothing() {
        let window = Passage.window(text: "  \n\n \t ", offset: 2)
        XCTAssertEqual(window.sentences, [])
        XCTAssertNil(window.currentIndex)
    }

    func testStartOfTextShowsNothingEarlierAndTheNextThree() {
        let window = passage(six, at: "One")
        XCTAssertEqual(texts(window), ["One.", "Two.", "Three.", "Four."])
        XCTAssertEqual(window.currentIndex, 0)
        XCTAssertFalse(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
        XCTAssertEqual(window.sentences.map(\.isCurrent), [true, false, false, false])
    }

    func testMiddleOfTextShowsOneBeforeAndThreeAfter() {
        let window = passage(six, at: "Two")
        XCTAssertEqual(texts(window), ["One.", "Two.", "Three.", "Four.", "Five."])
        XCTAssertEqual(window.currentIndex, 1)
        XCTAssertFalse(window.hasEarlier, "One. is the first sentence, so nothing is cut off before it")
        XCTAssertTrue(window.hasLater)
    }

    func testEndOfTextShowsNothingLater() {
        let window = passage(six, at: "Six")
        XCTAssertEqual(texts(window), ["Five.", "Six."])
        XCTAssertEqual(window.currentIndex, 1)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertFalse(window.hasLater)
    }

    func testOffsetPastTheEndLightsTheLastSentence() {
        let window = Passage.window(text: six, offset: 5_000)
        XCTAssertEqual(texts(window), ["Five.", "Six."])
        XCTAssertEqual(window.sentences.last?.isCurrent, true)
    }

    func testNegativeOffsetLightsTheFirstSentence() {
        let window = Passage.window(text: six, offset: -12)
        XCTAssertEqual(window.currentIndex, 0)
        XCTAssertEqual(texts(window).first, "One.")
    }

    func testOffsetInsideASentenceLightsThatSentence() {
        let window = Passage.window(text: six, offset: offset(of: "Three", in: six) + 3)
        XCTAssertEqual(window.sentences.first(where: \.isCurrent)?.text, "Three.")
    }

    func testSpaceAfterASentenceBelongsToIt() {
        // The offset sits on the space between "Two." and "Three."
        let window = Passage.window(text: six, offset: offset(of: "Three", in: six) - 1)
        XCTAssertEqual(window.sentences.first(where: \.isCurrent)?.text, "Two.")
    }

    func testCustomWindowSizes() {
        let window = passage(six, at: "Three", before: 0, after: 1)
        XCTAssertEqual(texts(window), ["Three.", "Four."])
        XCTAssertEqual(window.currentIndex, 0)
        let none = passage(six, at: "Three", before: -3, after: -3)
        XCTAssertEqual(texts(none), ["Three."], "a negative size is treated as zero")
    }

    func testSentenceStartAndEndAreCharacterOffsetsWithoutTheSpace() {
        let window = passage(six, at: "Two")
        let two = window.sentences[1]
        XCTAssertEqual(two.start, 5)
        XCTAssertEqual(two.end, 9)
        XCTAssertEqual(two.id, 5)
        XCTAssertEqual(String(Array(six)[two.start..<two.end]), "Two.")
    }

    // MARK: Chapters

    private let book = "Intro one. Intro two. Intro three. Part two begins here. It goes on. It ends."

    func testWindowStopsAtTheEndOfTheChapter() {
        let chapters = [
            chapter("c1", "Intro", in: book, from: "Intro one", to: "Part two"),
            chapter("c2", "Part two", in: book, from: "Part two", to: nil)
        ]
        let window = passage(book, at: "Intro two", chapters: chapters)
        XCTAssertEqual(window.chapterTitle, "Intro")
        XCTAssertEqual(texts(window), ["Intro one.", "Intro two.", "Intro three."])
        XCTAssertFalse(window.hasLater, "the next chapter's text is not part of this chapter's passage")
    }

    func testWindowStartsAtTheChapterStart() {
        let chapters = [
            chapter("c1", "Intro", in: book, from: "Intro one", to: "Part two"),
            chapter("c2", "Part two", in: book, from: "Part two", to: nil)
        ]
        let window = passage(book, at: "Part two", chapters: chapters)
        XCTAssertEqual(window.chapterTitle, "Part two")
        XCTAssertEqual(texts(window), ["Part two begins here.", "It goes on.", "It ends."])
        XCTAssertEqual(window.currentIndex, 0)
        XCTAssertFalse(window.hasEarlier)
    }

    func testTheLastCharacterOfAChapterStaysInThatChapter() {
        let chapters = [
            chapter("c1", "Intro", in: book, from: "Intro one", to: "Part two"),
            chapter("c2", "Part two", in: book, from: "Part two", to: nil)
        ]
        let boundary = offset(of: "Part two", in: book)
        XCTAssertEqual(Passage.window(text: book, chapters: chapters, offset: boundary - 1).chapterTitle, "Intro")
        XCTAssertEqual(Passage.window(text: book, chapters: chapters, offset: boundary).chapterTitle, "Part two")
    }

    func testNoChaptersMeansNoTitleAndTheWholeText() {
        let window = Passage.window(text: six, offset: 0)
        XCTAssertNil(window.chapterTitle)
    }

    func testChapterPastTheEndOfTheTextIsClamped() {
        let chapters = [Chapter(id: "c1", title: "All", startChar: 0, endChar: 99_999, percent: 0)]
        let window = Passage.window(text: six, chapters: chapters, offset: 0)
        XCTAssertEqual(window.chapterTitle, "All")
        XCTAssertEqual(texts(window), ["One.", "Two.", "Three.", "Four."])
    }

    func testOffsetBeforeTheFirstChapterUsesTheFirstChapter() {
        let chapters = [chapter("c2", "Part two", in: book, from: "Part two", to: nil)]
        let window = Passage.window(text: book, chapters: chapters, offset: 0)
        XCTAssertEqual(window.chapterTitle, "Part two")
        XCTAssertEqual(window.currentIndex, 0)
    }

    func testOffsetInAGapBetweenChaptersUsesTheEarlierChapter() {
        let chapters = [
            Chapter(id: "c1", title: "One", startChar: 0, endChar: 10, percent: 0),
            Chapter(id: "c2", title: "Two", startChar: 22, endChar: book.count, percent: 50)
        ]
        XCTAssertEqual(Passage.window(text: book, chapters: chapters, offset: 15).chapterTitle, "One")
    }

    func testAMarginInAnotherChapterGetsNoDiamond() {
        let chapters = [
            chapter("c1", "Intro", in: book, from: "Intro one", to: "Part two"),
            chapter("c2", "Part two", in: book, from: "Part two", to: nil)
        ]
        let elsewhere = Passage.Margin(id: "far", offset: offset(of: "It goes", in: book), origin: .own)
        let window = passage(book, at: "Intro two", chapters: chapters, margins: [elsewhere])
        XCTAssertEqual(window.sentences.flatMap(\.diamonds), [])
    }

    // MARK: Margins

    func testAMarginOnTheCurrentSentenceShowsAsADiamondThere() {
        let margin = Passage.Margin(id: "m1", offset: offset(of: "Three", in: six) + 2, origin: .own)
        let window = passage(six, at: "Three", margins: [margin])
        let current = window.sentences.first(where: \.isCurrent)
        XCTAssertEqual(current?.text, "Three.")
        XCTAssertEqual(current?.diamonds, [.init(id: "m1", origin: .own)])
        XCTAssertEqual(window.sentences.filter { !$0.diamonds.isEmpty }.count, 1)
    }

    func testOwnAndSharedMarginsLandOnTheirOwnSentences() {
        let margins = [
            Passage.Margin(id: "own", offset: offset(of: "Two", in: six), origin: .own),
            Passage.Margin(id: "shared", offset: offset(of: "Four", in: six), origin: .shared)
        ]
        let window = passage(six, at: "Three", margins: margins)
        XCTAssertEqual(texts(window), ["Two.", "Three.", "Four.", "Five.", "Six."])
        XCTAssertEqual(window.sentences.map { $0.diamonds.map(\.id) }, [["own"], [], ["shared"], [], []])
        XCTAssertEqual(window.sentences[0].diamonds.first?.origin, .own)
        XCTAssertEqual(window.sentences[2].diamonds.first?.origin, .shared)
    }

    func testTwoMarginsInOneSentenceKeepTextOrderThenId() {
        let at = offset(of: "Three", in: six)
        let margins = [
            Passage.Margin(id: "b", offset: at + 1, origin: .shared),
            Passage.Margin(id: "z", offset: at, origin: .own),
            Passage.Margin(id: "a", offset: at + 1, origin: .own)
        ]
        let window = passage(six, at: "Three", margins: margins)
        XCTAssertEqual(window.sentences.first(where: \.isCurrent)?.diamonds.map(\.id), ["z", "a", "b"])
    }

    func testAMarginInTheSpaceAfterASentenceBelongsToThatSentence() {
        let margin = Passage.Margin(id: "gap", offset: offset(of: "Three", in: six) - 1, origin: .own)
        let window = passage(six, at: "Two", margins: [margin])
        XCTAssertEqual(window.sentences.first(where: { $0.text == "Two." })?.diamonds.map(\.id), ["gap"])
    }

    func testMarginsOutsideTheShownSentencesAreLeftOut() {
        let margins = [
            Passage.Margin(id: "early", offset: 0, origin: .own),
            Passage.Margin(id: "late", offset: offset(of: "Six", in: six), origin: .shared)
        ]
        let window = passage(six, at: "Three", margins: margins, before: 1, after: 2)
        XCTAssertEqual(texts(window), ["Two.", "Three.", "Four.", "Five."])
        XCTAssertEqual(window.sentences.flatMap(\.diamonds), [])
    }

    func testMarginsWithOffsetsOutsideTheTextAreLeftOut() {
        let margins = [
            Passage.Margin(id: "neg", offset: -4, origin: .own),
            Passage.Margin(id: "past", offset: six.count + 50, origin: .own)
        ]
        let window = Passage.window(text: six, offset: six.count, margins: margins)
        XCTAssertEqual(window.sentences.flatMap(\.diamonds), [])
    }

    func testAMarginAtTheVeryEndOfTheTextIsOnTheLastSentence() {
        let margin = Passage.Margin(id: "end", offset: six.count, origin: .own)
        let window = Passage.window(text: six, offset: six.count, margins: [margin])
        XCTAssertEqual(window.sentences.last?.diamonds.map(\.id), ["end"])
    }

    // MARK: Where a sentence ends

    private func split(_ text: String) -> [String] {
        texts(Passage.window(text: text, offset: 0, sentencesAfter: 1_000))
    }

    func testSentenceEndsTable() {
        let cases: [(String, [String])] = [
            ("Plain one. Plain two.", ["Plain one.", "Plain two."]),
            ("Really? Yes! Fine.", ["Really?", "Yes!", "Fine."]),
            ("Wait?! No way.", ["Wait?!", "No way."]),
            ("He paused... Then left.", ["He paused...", "Then left."]),
            ("She said \"stop.\" He did.", ["She said \"stop.\"", "He did."]),
            ("(See below.) Next part.", ["(See below.)", "Next part."]),
            ("It cost 3.5 million. Fine.", ["It cost 3.5 million.", "Fine."]),
            ("Dr. Smith agreed. Mr. Jones did not.", ["Dr. Smith agreed.", "Mr. Jones did not."]),
            ("Ask J. Smith about it. Then go.", ["Ask J. Smith about it.", "Then go."]),
            ("Some fruit, e.g. apples, keep. Others don't.", ["Some fruit, e.g. apples, keep.", "Others don't."]),
            ("Smith et al. said so. Others differ.", ["Smith et al. said so.", "Others differ."]),
            ("We sell apples, pears, etc. and more. Done.", ["We sell apples, pears, etc. and more.", "Done."]),
            ("It was a Big Co. The end.", ["It was a Big Co.", "The end."]),
            ("Made in the U.S. The rest follows.", ["Made in the U.S.", "The rest follows."]),
            ("No stop at all", ["No stop at all"]),
            ("Ends here.", ["Ends here."]),
            ("Visit example.com today. Bye.", ["Visit example.com today.", "Bye."]),
            ("First paragraph\n\nSecond paragraph", ["First paragraph", "Second paragraph"]),
            ("First line\nsame sentence. Next.", ["First line\nsame sentence.", "Next."]),
            ("Wrapped lines\r\ncontinue here.\r\n\r\nNew one.", ["Wrapped lines\r\ncontinue here.", "New one."]),
            ("  Leading space. Then more.  ", ["Leading space.", "Then more."]),
            ("I said no. Then left.", ["I said no.", "Then left."]),
            ("So did I. Then we left.", ["So did I.", "Then we left."]),
            ("See No. 5 for more. Done.", ["See No. 5 for more.", "Done."]),
            ("See p. 5. Then.", ["See p. 5.", "Then."]),
            ("We met in Mar. 5 people came.", ["We met in Mar. 5 people came."]),
            ("\"Why?\" he asked. Fine.", ["\"Why?\" he asked.", "Fine."]),
            ("\"Fine.\" she said. \"Go.\" He went.", ["\"Fine.\" she said.", "\"Go.\"", "He went."]),
            ("\"Why?\" He asked. Fine.", ["\"Why?\"", "He asked.", "Fine."]),
            ("1. Apples\n2. Pears\n12. Plums", ["1. Apples", "2. Pears", "12. Plums"]),
            ("In 2020. 5 people came.", ["In 2020.", "5 people came."]),
            ("Tab\tseparated.\tNext.", ["Tab\tseparated.", "Next."]),
            ("Emoji 🎉 time. Next 👨‍👩‍👧 one.", ["Emoji 🎉 time.", "Next 👨‍👩‍👧 one."]),
            ("Café closed. Caf\u{65}\u{301} open.", ["Café closed.", "Caf\u{65}\u{301} open."])
        ]
        for (input, expected) in cases {
            XCTAssertEqual(split(input), expected, "input: \(input.debugDescription)")
        }
    }

    func testOffsetsCountCharactersNotUnicodeScalars() {
        // A family emoji and a decomposed é are one Character each, like the offsets the speech queue reports.
        let text = "Emoji 👨‍👩‍👧 time. Caf\u{65}\u{301} open. Last."
        let window = passage(text, at: "Last")
        XCTAssertEqual(window.sentences.first(where: \.isCurrent)?.text, "Last.")
        XCTAssertEqual(window.sentences.first(where: \.isCurrent)?.start, Array(text).count - 5)
    }

    func testLookalikeStopsInsideWordsAndNumbersDoNotSplit() {
        XCTAssertEqual(split("Version 1.2.3 shipped. Then 4.0 did."), ["Version 1.2.3 shipped.", "Then 4.0 did."])
        XCTAssertEqual(split("Email a.b@c.org now. Thanks."), ["Email a.b@c.org now.", "Thanks."])
    }

    func testCaseOfTheAbbreviationDoesNotMatter() {
        XCTAssertEqual(split("DR. SMITH SPOKE. DONE."), ["DR. SMITH SPOKE.", "DONE."])
    }

    func testARunWithNoSentenceEndIsCutAtASpace() {
        let words = Array(repeating: "word", count: 200).joined(separator: " ")
        let pieces = split(words)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, Passage.maxSentenceLength + 1)
            XCTAssertFalse(piece.hasPrefix(" "))
            XCTAssertFalse(piece.hasSuffix(" "))
        }
        XCTAssertEqual(pieces.joined(separator: " "), words, "nothing is lost or repeated by the cut")
    }

    func testARunWithNoSpacesIsCutAtTheLimit() {
        let blob = String(repeating: "x", count: 1_000)
        let pieces = split(blob)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertEqual(pieces.joined(), blob)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= Passage.maxSentenceLength + 1 })
    }

    func testEverySentenceHasTheOffsetsOfItsText() {
        let text = "  First one. Second, longer, one!\n\nThird?  Fourth\nwraps here.  "
        let chars = Array(text)
        let window = Passage.window(text: text, offset: 0, sentencesAfter: 100)
        XCTAssertEqual(window.sentences.count, 4)
        for sentence in window.sentences {
            XCTAssertEqual(String(chars[sentence.start..<sentence.end]), sentence.text)
        }
        XCTAssertEqual(window.sentences.map(\.start), window.sentences.map(\.start).sorted())
        XCTAssertEqual(Set(window.sentences.map(\.id)).count, 4)
    }

    func testAVeryLongTextIsHandled() {
        let text = String(repeating: "A sentence goes here. ", count: 20_000)
        let window = Passage.window(text: text, offset: 250_000)
        XCTAssertEqual(window.sentences.count, 5)
        XCTAssertTrue(window.hasEarlier)
        XCTAssertTrue(window.hasLater)
        XCTAssertEqual(window.sentences[window.currentIndex ?? 0].isCurrent, true)
    }
}
