import Foundation
import XCTest
@testable import SessionKit

/// #4453: the Now tab shows the whole scene, not 1 sentence before and 3 after.
final class PlaybackLivePassageSceneTests: XCTestCase {
    private typealias Passage = PlaybackLivePassage

    private func sentences(_ count: Int, prefix: String) -> String {
        (1...count).map { "\(prefix) sentence number \($0) says something." }.joined(separator: " ")
    }

    /// Three chapters; the middle one has 40 sentences.
    private func threeChapters() -> (text: String, chapters: [Chapter], middleStart: Int) {
        let first = sentences(5, prefix: "Opening")
        let middle = sentences(40, prefix: "Middle")
        let last = sentences(6, prefix: "Closing")
        let text = [first, middle, last].joined(separator: " ")
        let middleStart = first.count + 1
        let lastStart = middleStart + middle.count + 1
        let chapters = [
            Chapter(id: "c1", title: "One", startChar: 0, endChar: middleStart, percent: 0),
            Chapter(id: "c2", title: "Two", startChar: middleStart, endChar: lastStart, percent: 0),
            Chapter(id: "c3", title: "Three", startChar: lastStart, endChar: text.count, percent: 0)
        ]
        return (text, chapters, middleStart)
    }

    /// Fails on `main`: today's window gives 5 of the 40.
    func testSceneHoldsEverySentenceOfItsChapter() throws {
        let (text, chapters, middleStart) = threeChapters()
        var index = Passage.Index(text: text, chapters: chapters)
        let playhead = (text as NSString).range(of: "Middle sentence number 20").location
        XCTAssertGreaterThan(playhead, middleStart)
        index.updateScene(offset: playhead)

        let scene = index.scene
        XCTAssertEqual(scene.chapterTitle, "Two")
        XCTAssertEqual(scene.chapterStart, middleStart)
        XCTAssertEqual(scene.sentences.count, 40)
        XCTAssertEqual(scene.sentences.first?.text, "Middle sentence number 1 says something.")
        XCTAssertEqual(scene.sentences.last?.text, "Middle sentence number 40 says something.")
        XCTAssertEqual(index.currentSentence, 19)
        XCTAssertTrue(scene.sentences.allSatisfy { !$0.isCurrent }, "the light is currentSentence, not a row")
        XCTAssertEqual(Passage.window(text: text, chapters: chapters, offset: playhead).sentences.count, 5, "today's window")
    }

    func testAnItemWithNoChaptersIsOneSceneOfTheWholeText() {
        let text = sentences(30, prefix: "Only")
        var index = Passage.Index(text: text)
        index.updateScene(offset: 0)
        XCTAssertEqual(index.scene.sentences.count, 30)
        XCTAssertNil(index.scene.chapterTitle)
        XCTAssertEqual(index.scene.chapterStart, 0)
    }

    func testTicksAndSeeksInsideTheSceneChangeNoRowAndBuildNoneAgain() throws {
        let (text, chapters, middleStart) = threeChapters()
        var index = Passage.Index(text: text, chapters: chapters)
        XCTAssertEqual(index.updateScene(offset: middleStart + 1), .scene)
        let chapter = try XCTUnwrap(index.chapter)
        let rows = index.scene
        XCTAssertEqual(chapter.rowBuildCount, 1)

        // Same sentence: nothing changes.
        XCTAssertEqual(index.updateScene(offset: middleStart + 2), .none)
        // The next sentences and a seek back: only the light moves.
        for needle in ["Middle sentence number 2", "Middle sentence number 30", "Middle sentence number 3 "] {
            let offset = (text as NSString).range(of: needle).location
            XCTAssertEqual(index.updateScene(offset: offset), .lit, needle)
            XCTAssertEqual(index.scene, rows, "no row changed: \(needle)")
            XCTAssertTrue(index.chapter === chapter)
        }
        XCTAssertEqual(chapter.rowBuildCount, 1, "rows are built once per chapter however many ticks and seeks follow")
    }

    func testAnotherChapterIsAnotherSceneAndComingBackBuildsNothingAgain() throws {
        let (text, chapters, middleStart) = threeChapters()
        var index = Passage.Index(text: text, chapters: chapters)
        index.updateScene(offset: middleStart + 1)
        let middle = try XCTUnwrap(index.chapter)
        XCTAssertEqual(index.updateScene(offset: 0), .scene)
        XCTAssertEqual(index.scene.chapterTitle, "One")
        XCTAssertEqual(index.scene.sentences.count, 5)
        XCTAssertEqual(index.updateScene(offset: middleStart + 1), .scene)
        XCTAssertTrue(index.chapter === middle)
        XCTAssertEqual(middle.rowBuildCount, 1)
    }

    func testMarginsReplaceOnlyTheRowsTheySitOn() {
        let (text, chapters, middleStart) = threeChapters()
        var index = Passage.Index(text: text, chapters: chapters)
        index.updateScene(offset: middleStart + 1)
        let before = index.scene
        let at = (text as NSString).range(of: "Middle sentence number 12").location + 3
        let margins = [
            Passage.Margin(id: "b", offset: at + 2, origin: .shared), Passage.Margin(id: "a", offset: at, origin: .own),
            Passage.Margin(id: "elsewhere", offset: 0, origin: .own) // in another chapter: left out
        ]
        XCTAssertEqual(index.updateScene(offset: middleStart + 1, margins: margins), .scene)
        let changed = zip(before.sentences, index.scene.sentences).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(changed, [11], "only sentence 12 gained diamonds")
        XCTAssertEqual(index.scene.sentences[11].diamonds.map(\.id), ["a", "b"], "text order, ties by id")
        XCTAssertEqual(index.chapter?.rowBuildCount, 1, "the rows were not built again for the Margins")
    }

    /// Found by the review: a chapter with no sentence and a Margin inside it trapped on `rows[0]`.
    func testAChapterWithNoSentenceHasAnEmptySceneEvenWithAMarginInIt() throws {
        let text = "Intro sentence one. Intro sentence two.   \n\n   "
        let blankStart = "Intro sentence one. Intro sentence two.".count
        let chapters = [
            Chapter(id: "a", title: "Words", startChar: 0, endChar: blankStart, percent: 0),
            Chapter(id: "b", title: "Blank", startChar: blankStart, endChar: text.count, percent: 0),
            Chapter(id: "c", title: "Empty end", startChar: text.count, endChar: text.count, percent: 0)
        ]
        var index = Passage.Index(text: text, chapters: chapters)
        for offset in [blankStart + 2, text.count] {
            let margins = [Passage.Margin(id: "m", offset: offset, origin: .own)]
            index.updateScene(offset: offset, margins: margins)
            XCTAssertEqual(index.scene.sentences, [], "offset \(offset)")
            XCTAssertNil(index.currentSentence)
        }
        let blank = Passage.Index(text: "   \n  ")
        var whitespaceOnly = blank
        whitespaceOnly.updateScene(offset: 2, margins: [.init(id: "m", offset: 2, origin: .own)])
        XCTAssertEqual(whitespaceOnly.scene.sentences, [])
    }

    func testAMarginInAnotherChapterLeavesTheSceneAlone() {
        let (text, chapters, middleStart) = threeChapters()
        var index = Passage.Index(text: text, chapters: chapters)
        index.updateScene(offset: middleStart + 1)
        let elsewhere = [Passage.Margin(id: "x", offset: 3, origin: .own)]
        XCTAssertEqual(index.updateScene(offset: middleStart + 1, margins: elsewhere), .none)
        XCTAssertEqual(index.updateScene(offset: middleStart + 1, margins: []), .none)
    }

    func testAnOffsetBeforeAndAfterTheTextLightsTheFirstAndLastSentence() {
        let text = sentences(4, prefix: "Short")
        var index = Passage.Index(text: text)
        index.updateScene(offset: -5)
        XCTAssertEqual(index.currentSentence, 0)
        index.updateScene(offset: text.count + 50)
        XCTAssertEqual(index.currentSentence, 3)
    }

    func testNoTextIsAnEmptyScene() {
        var index = Passage.Index(text: "")
        XCTAssertEqual(index.updateScene(offset: 0), .none)
        XCTAssertEqual(index.scene, .empty)
        XCTAssertNil(index.currentSentence)
    }

    /// `long-source`: about 1.1 MB of text with no chapters, the book `GeneratedListeningMap` names.
    func testAMegabyteSceneHoldsEverySentenceAndATickRebuildsNothing() throws {
        let sentence = "The harbour light moved slowly across the water while the town slept. "
        let text = String(repeating: sentence, count: 1_100_000 / sentence.count)
        var index = Passage.Index(text: text)
        XCTAssertEqual(index.updateScene(offset: 0), .scene)
        let count = index.scene.sentences.count
        XCTAssertGreaterThan(count, 10_000)
        XCTAssertEqual(index.updateScene(offset: text.count / 2), .lit)
        XCTAssertEqual(index.scene.sentences.count, count)
        XCTAssertEqual(try XCTUnwrap(index.chapter).rowBuildCount, 1)
        let lit = try XCTUnwrap(index.currentSentence)
        XCTAssertEqual(index.updateScene(offset: text.count / 2 + 1), lit == index.currentSentence ? .none : .lit)
    }

    /// Reported, not asserted (#4453 Done when 5): the time to build a scene's rows.
    func testBuildingTheRowsOfABigSceneIsMeasured() {
        let text = String(repeating: "The harbour light moved slowly across the water while the town slept. ", count: 15_000)
        measure {
            var index = Passage.Index(text: text)
            index.updateScene(offset: 0)
            XCTAssertGreaterThan(index.scene.sentences.count, 10_000)
        }
    }
}
