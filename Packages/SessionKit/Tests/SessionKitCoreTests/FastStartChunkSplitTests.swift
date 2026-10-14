import Foundation
import XCTest
@testable import SessionKit

/// #849: after a fallback to the bundled voice the first chunk is split so audio starts quickly. The split only
/// touches the live plan: the other chunks, and the article plan that prepared audio matches, stay as planned.
final class FastStartChunkSplitTests: XCTestCase {
    private func plan(_ text: String) -> NarrationChunkPlanner.SpokenPlan {
        NarrationChunkPlanner.spokenPlan(spokenText: text, articleText: nil, articleSpokenStart: 0)
    }

    private func assertCoversExactly(
        _ split: [NarrationChunkPlanner.SpokenChunk], _ original: [NarrationChunkPlanner.SpokenChunk],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(split.first?.startOffset, original.first?.startOffset, file: file, line: line)
        for (a, b) in zip(split, split.dropFirst()) {
            XCTAssertEqual(a.startOffset + a.sourceLength, b.startOffset, "contiguous", file: file, line: line)
        }
        XCTAssertEqual(split.last.map { $0.startOffset + $0.sourceLength },
                       original.last.map { $0.startOffset + $0.sourceLength }, file: file, line: line)
        for chunk in split { XCTAssertFalse(chunk.text.isEmpty, file: file, line: line) }
    }

    /// Real prose: its plan is 180, 98, 99, 167 and 49 characters, so the first chunk is a full one.
    private let sentences = "The committee met on Tuesday to discuss the proposal, which had been circulating among members for several weeks and had attracted a surprising amount of criticism from both sides. Most of the objections concerned cost. A smaller group worried that the timeline was unrealistic, given how many agencies would have to coordinate their efforts across three separate fiscal years. In the end, the chair suggested a compromise that nobody liked but everyone could tolerate; the vote passed narrowly, seven to six, after nearly four hours of debate. Reporters outside the building waited for hours."

    func testAFullFirstChunkSplitsAtASentenceBoundaryIntoAShortHeadAndTheRest() {
        let original = plan(sentences).chunks
        XCTAssertGreaterThan(original.count, 1)
        let split = NarrationChunkPlanner.splittingFirstChunk(of: original, spokenText: sentences, playheadOffset: 0)
        XCTAssertEqual(split.count, original.count + 1)
        assertCoversExactly(split, original)
        XCTAssertEqual(original.map(\.sourceLength), [180, 98, 99, 167, 49])
        XCTAssertEqual(split.map(\.sourceLength), [53, 127, 98, 99, 167, 49])
        XCTAssertEqual(split[0].boundary, .comma)
        XCTAssertLessThanOrEqual(split[0].text.count, NarrationChunkPlanner.fastStartHeadBudget)
        XCTAssertNil(split[0].articleIndex)
        XCTAssertNil(split[1].articleIndex)
        XCTAssertEqual(Array(split.dropFirst(2)), Array(original.dropFirst()), "later chunks stay as planned")
    }

    func testTheChunkAtThePlayheadIsTheOneThatSplitsNotTheFirstOfTheArticle() {
        let original = plan(sentences).chunks
        let playhead = original[3].startOffset + 5
        let split = NarrationChunkPlanner.splittingFirstChunk(of: original, spokenText: sentences, playheadOffset: playhead)
        XCTAssertEqual(split.count, original.count + 1)
        assertCoversExactly(split, original)
        XCTAssertEqual(Array(split.prefix(3)), Array(original.prefix(3)))
        XCTAssertEqual(split[3].startOffset, original[3].startOffset)
        XCTAssertLessThan(split[3].sourceLength, original[3].sourceLength)
        XCTAssertEqual(split[5], original[4])
    }

    func testAChunkThatIsAlreadyShortIsLeftAlone() {
        for text in ["Short.", "One short sentence here.", "", "   ", "A", String(repeating: "word ", count: 10)] {
            let original = plan(text).chunks
            XCTAssertEqual(NarrationChunkPlanner.splittingFirstChunk(of: original, spokenText: text, playheadOffset: 0),
                           original, "[\(text)]")
        }
    }

    func testAPlayheadOutsideEveryChunkChangesNothing() {
        let original = plan(sentences).chunks
        XCTAssertEqual(NarrationChunkPlanner.splittingFirstChunk(
            of: original, spokenText: sentences, playheadOffset: sentences.count + 50), original)
        XCTAssertEqual(NarrationChunkPlanner.splittingFirstChunk(of: [], spokenText: sentences, playheadOffset: 0), [])
    }

    func testNeighbouringInputsStayContiguousAndNonEmpty() {
        let long = String(repeating: "supercalifragilisticexpialidocious", count: 20)
        let numbers = (1...40).map { "Table \($0) shows 91.\($0)% of 12,\($0)00 cases." }.joined(separator: " ")
        let accents = (1...20).map { "Café number \($0) naïve résumé, déjà vu 🎧 again and again." }.joined(separator: " ")
        let lines = (1...25).map { "line number \($0) without any full stop at all" }.joined(separator: "\n")
        let commas = (1...30).map { "clause \($0)" }.joined(separator: ", ")
        for (name, text) in [("one long word", long), ("numbers", numbers), ("accents and emoji", accents),
                             ("newlines", lines), ("commas only", commas), ("sentences", sentences)] {
            let original = plan(text).chunks
            for playhead in [0, text.count / 3, max(0, text.count - 3)] {
                let split = NarrationChunkPlanner.splittingFirstChunk(of: original, spokenText: text, playheadOffset: playhead)
                assertCoversExactly(split, original)
                XCTAssertGreaterThanOrEqual(split.count, original.count, name)
                XCTAssertLessThanOrEqual(split.count, original.count + 1, name)
            }
        }
    }

    func testTheArticlePlanAndItsIndexesAreUntouched() {
        let article = sentences
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: SpeechTextNormalizer.normalize(article), articleText: article, articleSpokenStart: 0)
        let before = spoken
        _ = NarrationChunkPlanner.splittingFirstChunk(of: spoken.chunks, spokenText: SpeechTextNormalizer.normalize(article), playheadOffset: 0)
        XCTAssertEqual(spoken, before)
        XCTAssertEqual(spoken.chunks.compactMap(\.articleIndex), Array(spoken.chunks.indices))
    }
}
