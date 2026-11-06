import Foundation
import SessionKit
import XCTest

/// #3450: how an article or PDF is cut into the scenes the on-device model summarises, against neighbouring inputs.
/// Every test checks the same promises: scenes are in order, touch end to end, stay inside the text, and none is longer
/// than the model's reading limit, so no part of a source goes unsummarised.
final class TextSceneSummaryPlannerTests: XCTestCase {
    private func chapters(_ starts: [Int], in text: String) -> [Chapter] {
        let count = text.count
        return starts.enumerated().map { index, start in
            Chapter(
                id: "ch-generated-\(String(format: "%02d", index + 1))", title: "Chapter \(index + 1)", startChar: start,
                endChar: index + 1 < starts.count ? starts[index + 1] : count, percent: 0
            )
        }
    }

    private func sentence(_ number: Int) -> String {
        "Sentence number \(number) says one plain thing about the market square and its stalls."
    }

    private func paragraphs(count: Int, sentencesEach: Int) -> String {
        (0..<count).map { paragraph in
            (0..<sentencesEach).map { sentence(paragraph * sentencesEach + $0) }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }

    private func assertCovers(_ drafts: [TextSceneDraft], text: String, maximum: Int = TextSceneSummaryPlanner.maximumSceneCharacters,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(drafts.isEmpty, file: file, line: line)
        XCTAssertEqual(drafts.first?.startChar, 0, file: file, line: line)
        XCTAssertEqual(drafts.last?.endChar, text.count, file: file, line: line)
        XCTAssertEqual(drafts.map(\.order), Array(0..<drafts.count), file: file, line: line)
        XCTAssertEqual(Set(drafts.map(\.id)).count, drafts.count, "scene ids are unique", file: file, line: line)
        for (previous, next) in zip(drafts, drafts.dropFirst()) {
            XCTAssertEqual(previous.endChar, next.startChar, "scenes touch", file: file, line: line)
        }
        for draft in drafts {
            XCTAssertLessThan(draft.startChar, draft.endChar, file: file, line: line)
            XCTAssertLessThanOrEqual(draft.endChar - draft.startChar, maximum, "\(draft.id) is within the reading limit", file: file, line: line)
            XCTAssertLessThanOrEqual(draft.modelText.count, maximum, file: file, line: line)
        }
    }

    // MARK: neighbouring inputs

    func testAVeryShortArticleIsOneSceneThatIsNotSummarised() {
        let text = "Short note."
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters([0], in: text))

        assertCovers(drafts, text: text)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertFalse(drafts[0].isSummarizable, "11 letters give the model nothing to summarise")
    }

    func testAShortButRealArticleIsOneSummarisableScene() {
        let text = sentence(1) + " " + sentence(2)
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters([0], in: text))

        assertCovers(drafts, text: text)
        XCTAssertEqual(drafts.map(\.isSummarizable), [true])
        XCTAssertEqual(drafts[0].modelText, text)
    }

    func testEmptyAndWhitespaceTextMakeNoScenes() {
        XCTAssertEqual(TextSceneSummaryPlanner.plan(text: "", chapters: []), [])
        let blank = TextSceneSummaryPlanner.plan(text: "  \n\n  ", chapters: [])
        XCTAssertFalse(blank.contains(where: \.isSummarizable))
    }

    func testOneLongParagraphIsSplitAtSentenceEndsIntoEvenScenes() {
        let text = (0..<400).map { sentence($0) }.joined(separator: " ") // one paragraph, about 34,000 characters
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters([0], in: text))

        assertCovers(drafts, text: text)
        XCTAssertGreaterThanOrEqual(drafts.count, 6)
        XCTAssertTrue(drafts.allSatisfy(\.isSummarizable))
        let characters = Array(text)
        for draft in drafts.dropFirst() {
            XCTAssertEqual(characters[draft.startChar - 1], " ", "a cut sits after a sentence's closing space: \(draft.id)")
            XCTAssertEqual(characters[draft.startChar - 2], ".", "and after its full stop: \(draft.id)")
        }
        let sizes = drafts.map { $0.endChar - $0.startChar }
        XCTAssertLessThan(sizes.max()! - sizes.min()!, TextSceneSummaryPlanner.maximumSceneCharacters / 2, "no sliver beside a full scene: \(sizes)")
    }

    func testASectionOverTheCapIsSplitNotCutOffAndKeepsItsChapterId() {
        let text = paragraphs(count: 40, sentencesEach: 4) // about 14,000 characters in blank-line paragraphs
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters([0], in: text))

        assertCovers(drafts, text: text)
        XCTAssertEqual(drafts.first?.id, "ch-generated-01")
        XCTAssertTrue(drafts.dropFirst().allSatisfy { $0.id.hasPrefix("ch-generated-01-part-") })
        let characters = Array(text)
        for draft in drafts.dropFirst() {
            XCTAssertEqual(characters[draft.startChar - 1], "\n", "blank lines are the preferred cut: \(draft.id)")
            XCTAssertEqual(characters[draft.startChar - 2], "\n")
        }
        XCTAssertEqual(drafts.dropFirst().first?.fallbackTitle, "Chapter 1 (continued)")
    }

    func testTheCapIsAParameterAndTextWithoutAnyBreakIsStillCutAtTheLimit() {
        let text = String(repeating: "a", count: 2_500) // no space, no full stop
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: [], maximumSceneCharacters: 1_000)

        assertCovers(drafts, text: text, maximum: 1_000)
        XCTAssertEqual(drafts.count, 3)
    }

    func testHeadingsOnlyHaveNothingToSummarise() {
        let text = "Introduction\n\nBackground\n\nMethods\n\nResults\n\nConclusion"
        let starts = [0, 14, 26, 35, 44]
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters(starts, in: text))

        assertCovers(drafts, text: text)
        XCTAssertFalse(drafts.contains(where: \.isSummarizable), "headings alone are not summarised")
    }

    func testAHeadingWithNoBodyJoinsTheSectionAfterItAndALastOneJoinsTheOneBefore() {
        let first = "Introduction\n\n"
        let body = sentence(1) + " " + sentence(2) + "\n\n"
        let second = "Second part\n\n" + sentence(3) + " " + sentence(4) + "\n\n"
        let tail = "The end"
        let text = first + body + second + tail
        let starts = [0, first.count, first.count + body.count, text.count - tail.count]
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters(starts, in: text))

        assertCovers(drafts, text: text)
        XCTAssertEqual(drafts.map(\.id), ["ch-generated-01", "ch-generated-03"], "the heading and the body are one scene; the tail joins the last")
        XCTAssertEqual(drafts.map(\.startChar), [0, first.count + body.count])
        XCTAssertTrue(drafts[0].modelText.hasPrefix("Introduction"))
        XCTAssertTrue(drafts[1].modelText.hasSuffix("The end"))
        XCTAssertTrue(drafts.allSatisfy(\.isSummarizable))
    }

    func testNonLatinTextIsPlannedByCharactersAndCutAtFullWidthSentenceEnds() {
        let line = "市場の広場には朝から多くの店が並び、人々は野菜や魚を買い求めて行き交っていた。"
        let text = String(repeating: line, count: 300) // no spaces at all, 300 sentences
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: [], maximumSceneCharacters: 2_000)

        assertCovers(drafts, text: text, maximum: 2_000)
        XCTAssertTrue(drafts.allSatisfy(\.isSummarizable), "Japanese letters count as letters")
        let characters = Array(text)
        for draft in drafts.dropFirst() {
            XCTAssertEqual(characters[draft.startChar - 1], "。", "cut after the full-width full stop: \(draft.id)")
        }
    }

    func testEmojiAndCombiningMarksAreCountedAsOneCharacterEachSoOffsetsMatchTheApp() {
        let text = "Cafe\u{301} talk 👩‍👩‍👧 " + sentence(1) + " " + sentence(2)
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters([0, 6], in: text))

        assertCovers(drafts, text: text)
        XCTAssertEqual(drafts.last?.endChar, text.count)
    }

    // MARK: PDFs

    func testRunningHeadsAndPageNumbersOfAMultiColumnPDFAreNotReadByTheModel() {
        let head = "Journal of Market Studies  Vol. 12"
        var pages: [String] = []
        for page in 1...6 {
            pages.append("\(head)\n\(sentence(page * 2))\nSecond column starts here and \(sentence(page * 2 + 1).lowercased())\nPage \(page) of 6")
        }
        let text = pages.joined(separator: "\n")
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: chapters([0, text.count / 2], in: text))

        assertCovers(drafts, text: text)
        for draft in drafts {
            XCTAssertFalse(draft.modelText.contains("Journal of Market Studies"), draft.modelText)
            XCTAssertFalse(draft.modelText.contains("Page "), draft.modelText)
            XCTAssertTrue(draft.modelText.contains("Sentence number"))
        }
        // The offsets still count the original text, headers and all.
        XCTAssertEqual(drafts.last?.endChar, text.count)
    }

    /// The audit on 946f910: a line that is only a year or a figure is text, not a page number.
    func testABodyLineThatIsOnlyAYearIsKeptAndABarePageNumberIsNot() {
        let text = sentence(1) + "\n1990\n" + sentence(2) + "\n12\n" + sentence(3)
        let model = TextSceneSummaryPlanner.plan(text: text, chapters: [])[0].modelText

        XCTAssertTrue(model.contains("\n1990\n"), model)
        XCTAssertFalse(model.contains("\n12\n"), model)
    }

    func testALineThatRepeatsOnlyTwiceIsKeptAndSoIsALongRepeatedLine() {
        let twice = "Sidebar note\n" + sentence(1) + "\nSidebar note\n" + sentence(2)
        let planned = TextSceneSummaryPlanner.plan(text: twice, chapters: [])
        XCTAssertTrue(planned[0].modelText.contains("Sidebar note"))

        let long = sentence(7) // longer than a running head can be, and a sentence
        let prose = (0..<4).map { _ in long + " " + long + " " + long }.joined(separator: "\n")
        XCTAssertTrue(TextSceneSummaryPlanner.plan(text: prose, chapters: [])[0].modelText.contains(long))
    }

    func testWindowsLineEndingsGetTheSameBlankLineCutsAndHeaderRemovalAsUnixOnes() {
        let unix = paragraphs(count: 40, sentencesEach: 4)
        let windows = unix.replacingOccurrences(of: "\n", with: "\r\n")
        let drafts = TextSceneSummaryPlanner.plan(text: windows, chapters: [])

        assertCovers(drafts, text: windows)
        let characters = Array(windows)
        for draft in drafts.dropFirst() {
            XCTAssertTrue(characters[draft.startChar - 1].isNewline && characters[draft.startChar - 2].isNewline, "blank-line cut: \(draft.id)")
        }
        let paged = (1...5).map { "Annual Review\r\n\(sentence($0))\r\n\($0)" }.joined(separator: "\r\n")
        let planned = TextSceneSummaryPlanner.plan(text: paged, chapters: [])
        XCTAssertFalse(planned[0].modelText.contains("Annual Review"), planned[0].modelText)
    }

    // MARK: sections

    func testChaptersOutOfOrderOrDuplicatedOrPastTheEndStillMakeOrderedScenes() {
        let text = paragraphs(count: 6, sentencesEach: 3)
        let messy = [
            Chapter(id: "late", title: "Late", startChar: text.count + 500, endChar: text.count, percent: 100),
            Chapter(id: "b", title: "B", startChar: 200, endChar: 400, percent: 0),
            Chapter(id: "b-again", title: "B", startChar: 200, endChar: 400, percent: 0),
            Chapter(id: "a", title: "A", startChar: 0, endChar: 200, percent: 0),
        ]
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: messy)

        assertCovers(drafts, text: text)
    }

    func testAFirstChapterThatDoesNotStartAtZeroStillCoversTheOpeningText() {
        let text = paragraphs(count: 4, sentencesEach: 3)
        let drafts = TextSceneSummaryPlanner.plan(text: text, chapters: [
            Chapter(id: "ch-generated-01", title: "One", startChar: 120, endChar: text.count, percent: 0),
        ])

        assertCovers(drafts, text: text)
        XCTAssertEqual(drafts.first?.startChar, 0)
    }

    func testPlanningIsRepeatable() {
        let text = paragraphs(count: 30, sentencesEach: 5)
        let chapters = chapters([0, 3_000, 9_000], in: text)
        XCTAssertEqual(
            TextSceneSummaryPlanner.plan(text: text, chapters: chapters),
            TextSceneSummaryPlanner.plan(text: text, chapters: chapters)
        )
    }
}
