import Foundation
import XCTest
@testable import SessionKit

/// #312: prepared audio is matched to an article by `ArticlePlan.identity` (the chunker's version and the article's
/// text) and its chunk boundaries are then recomputed, so the boundaries must be exactly the ones the audio was
/// rendered with. Nothing else holds them still: the planner tests in SessionKitTests compare the plan with the
/// chunker that produces it, and the chunker tests check rules (cost within budget, text covered, no split inside a
/// number) that any budget or boundary preference satisfies. A change to the budget, the cost limit or the boundary
/// characters would silently stop "ready offline" audio from matching.
///
/// These are the plans Build 30 produces, written out. If one fails because the chunking was changed on purpose,
/// bump `NarrationChunkPlanner.version` (which invalidates prepared audio, as it must) and regenerate the literals
/// below in the same commit.
final class NarrationChunkPlanGoldenTests: XCTestCase {
    private typealias Expected = (start: Int, length: Int, boundary: RenderedSpeechChunkBoundary, text: String)

    private func assertPlan(
        _ plan: NarrationChunkPlanner.ArticlePlan, _ expected: [Expected], _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(plan.chunks.map(\.index), Array(expected.indices), "\(name): indexes", file: file, line: line)
        XCTAssertEqual(plan.chunks.map(\.startOffset), expected.map(\.start), "\(name): start offsets", file: file, line: line)
        XCTAssertEqual(plan.chunks.map(\.sourceLength), expected.map(\.length), "\(name): source lengths", file: file, line: line)
        XCTAssertEqual(plan.chunks.map(\.boundary), expected.map(\.boundary), "\(name): boundaries", file: file, line: line)
        XCTAssertEqual(plan.chunks.map(\.text), expected.map(\.text), "\(name): texts", file: file, line: line)
    }

    // MARK: Version

    func testTheChunkerVersionAndTheCostBudgetAreWhatPreparedAudioWasMadeWith() {
        XCTAssertEqual(NarrationChunkPlanner.version, "rendered-speech-chunker.v2")
        XCTAssertEqual(RenderedSpeechChunker.spokenCostBudget, 180)
        // The identity is the version and the text hashed together, so a new version makes every old one differ.
        XCTAssertEqual(NarrationChunkPlanner.identity(ofArticle: "A short article."),
                       "0b22275fa55ac00dbd00b3b1156fa841fcb35286e253a6152f5be64231893e7f")
    }

    // MARK: Whole articles

    private func sentence(_ number: Int) -> String {
        "Sentence \(number) of the article reports 91.1% across 7,494 decisions, which the chunker must split carefully."
    }

    func testNineSentenceArticleIsSplitAtItsSentences() {
        let article = (1...9).map(sentence).joined(separator: " ")
        let plan = NarrationChunkPlanner.articlePlan(article)
        XCTAssertEqual(plan.normalizedText, article)
        XCTAssertEqual(plan.identity, "182e987ec776f9a58fc4bf49fbcbf9468c2f9869062bfa280eebb023e344e846")
        assertPlan(plan, [
            (0, 103, .sentence, sentence(1)),
            (103, 104, .sentence, sentence(2)),
            (207, 104, .sentence, sentence(3)),
            (311, 104, .sentence, sentence(4)),
            (415, 104, .sentence, sentence(5)),
            (519, 104, .sentence, sentence(6)),
            (623, 104, .sentence, sentence(7)),
            (727, 104, .sentence, sentence(8)),
            (831, 104, .sentence, sentence(9)),
        ], "nine sentences")
    }

    /// A results table flattened into prose by PDF extraction (arXiv:2608.09666), the text the cost budget was set for.
    static let tableSpan = """
    Table 3 reports agreement with human judges across benchmarks. Model Overall Win Tie Loss VBench 0.8889 91.1% 8.9% 0.0 \
    T2I-CompBench 0.7421 74.2% 25.8% 0.0 GenEval 0.8125 81.3% 12.5% 6.2% Qwen2.5-VL-7B 0.6923 69.2% 23.1% 7.7% \
    GPT-4o 0.8571 85.7% 14.3% 0.0 Ours 0.9286 92.9% 7.1% 0.0 Steps 7,494 tool decisions 2,548 summaries 1,203 retries \
    312 failures Latency 12.4 s 3.8 s 0.9 s 0.27 s Cost $0.021 $0.004 $0.0007 per query, n = 1,024, p < 0.001, \
    σ = 0.042, 95% CI [0.871, 0.913].
    The evaluation agent adapts its trajectory to intermediate evidence and user specified criteria, which reduces the \
    number of samples it needs while keeping its judgments close to those of human raters.
    """

    func testNumberHeavyTableSpanIsSplitWhereTheCostBudgetAndBoundaryPreferencesSaySo() {
        let plan = NarrationChunkPlanner.articlePlan(Self.tableSpan)
        XCTAssertEqual(plan.identity, "87f75bf8e47609d66c963951ea011f392817cde68ebc03f4e59934335d74a2aa")
        assertPlan(plan, [
            (0, 62, .sentence, "Table 3 reports agreement with human judges across benchmarks."),
            (62, 90, .whitespace, "Model Overall Win Tie Loss VBench 0.8889 91.1% 8.9% 0.0 T2I-CompBench 0.7421 74.2% 25.8%"),
            (152, 69, .whitespace, "0.0 GenEval 0.8125 81.3% 12.5% 6.2% Qwen2.5-VL-7B 0.6923 69.2% 23.1%"),
            (221, 68, .whitespace, "7.7% GPT-4o 0.8571 85.7% 14.3% 0.0 Ours 0.9286 92.9% 7.1% 0.0 Steps"),
            (289, 103, .whitespace, "7,494 tool decisions 2,548 summaries 1,203 retries 312 failures Latency 12.4 s 3.8 s 0.9 s 0.27 s Cost"),
            (392, 65, .comma, "$0.021 $0.004 $0.0007 per query, n = 1,024, p < 0.001, σ = 0.042,"),
            (457, 120, .comma, "95% CI [0.871, 0.913]. The evaluation agent adapts its trajectory to intermediate evidence and user specified criteria,"),
            (577, 105, .sentence, "which reduces the number of samples it needs while keeping its judgments close to those of human raters."),
        ], "table span")
    }

    func testThePlayersPlanWithAPrefaceIsTheArticlePlanAfterTheOverviewChunk() {
        let article = (1...9).map(sentence).joined(separator: " ")
        let preface = "Overview. The paper studies evaluation agents and how they choose their tools.\n\n"
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(preface + article)
        let start = projection.spokenCharacterOffset(atOrAfterSourceOffset: preface.count)
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: projection.text, articleText: article, articleSpokenStart: start)
        XCTAssertEqual(start, 79)
        XCTAssertEqual(spoken.articleSpokenStart, 79)
        XCTAssertEqual(spoken.articleIdentity, "182e987ec776f9a58fc4bf49fbcbf9468c2f9869062bfa280eebb023e344e846")
        let chunks = spoken.chunks.map { (start: $0.startOffset, length: $0.sourceLength, boundary: $0.boundary, article: $0.articleIndex) }
        let expected: [(Int, Int, RenderedSpeechChunkBoundary, Int?)] = [
            (0, 79, .sentence, nil),
            (79, 103, .sentence, 0), (182, 104, .sentence, 1), (286, 104, .sentence, 2), (390, 104, .sentence, 3),
            (494, 104, .sentence, 4), (598, 104, .sentence, 5), (702, 104, .sentence, 6), (806, 104, .sentence, 7),
            (910, 104, .sentence, 8),
        ]
        XCTAssertEqual(chunks.count, expected.count)
        for (chunk, wanted) in zip(chunks, expected) {
            XCTAssertEqual([chunk.start, chunk.length], [wanted.0, wanted.1])
            XCTAssertEqual(chunk.boundary, wanted.2)
            XCTAssertEqual(chunk.article, wanted.3)
        }
    }

    // MARK: Where the budget ends

    private func lengths(of plan: NarrationChunkPlanner.ArticlePlan) -> [Int] { plan.chunks.map(\.sourceLength) }

    func testTextExactlyAtTheCostBudgetIsOneChunkAndOneOverIsTwo() {
        let budget = RenderedSpeechChunker.spokenCostBudget
        XCTAssertEqual(lengths(of: NarrationChunkPlanner.articlePlan(String(repeating: "a", count: budget))), [180])
        let over = NarrationChunkPlanner.articlePlan(String(repeating: "a", count: budget + 1))
        assertPlan(over, [(0, 180, .hard, String(repeating: "a", count: 180)), (180, 1, .hard, "a")], "181 letters")
    }

    func testDigitsCostFourEachSoTheBudgetEndsAt45OfThem() {
        XCTAssertEqual(lengths(of: NarrationChunkPlanner.articlePlan(String(repeating: "7", count: 45))), [45], "45 x 4 = 180")
        let over = NarrationChunkPlanner.articlePlan(String(repeating: "7", count: 46))
        assertPlan(over, [(0, 45, .hard, String(repeating: "7", count: 45)), (45, 1, .hard, "7")], "46 digits")
    }

    func testAnUnbrokenTokenIsCutHardAtTheBudget() {
        let plan = NarrationChunkPlanner.articlePlan(String(repeating: "x", count: 500))
        assertPlan(plan, [
            (0, 180, .hard, String(repeating: "x", count: 180)),
            (180, 180, .hard, String(repeating: "x", count: 180)),
            (360, 140, .hard, String(repeating: "x", count: 140)),
        ], "500-letter token")
    }

    func testAnEmptyOrBlankArticleHasNoChunks() {
        for text in ["", "   \n  "] {
            let plan = NarrationChunkPlanner.articlePlan(text)
            XCTAssertEqual(plan.chunks, [], "\(text.debugDescription)")
            XCTAssertEqual(plan.normalizedText, "")
        }
        XCTAssertEqual(RenderedSpeechChunker.sourceSlices(from: ""), [])
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: "", articleText: "", articleSpokenStart: 0)
        XCTAssertEqual(spoken.chunks, [])
        XCTAssertNil(spoken.articleIdentity)
        XCTAssertEqual(spoken.articleSpokenStart, 0)
    }

    // MARK: Boundaries

    /// The marks that end a sentence for the chunker. Each is the last one inside the first 74 characters, with no
    /// other mark and only spaces after it, so the chunk ends at it only if the chunker treats it as a sentence end.
    func testEachSentenceMarkEndsAChunkAtItsLastOccurrence() {
        for mark in [".", "!", "?", ";", ":"] {
            let text = String(repeating: "word ", count: 14) + "end" + mark + String(repeating: " more", count: 30)
            let plan = NarrationChunkPlanner.articlePlan(text)
            XCTAssertEqual(plan.chunks.first?.sourceLength, 74, "'\(mark)'")
            XCTAssertEqual(plan.chunks.first?.boundary, .sentence, "'\(mark)'")
            XCTAssertEqual(plan.chunks.first?.text, String(repeating: "word ", count: 14) + "end" + mark, "'\(mark)'")
            XCTAssertEqual(lengths(of: plan), [74, 146, 4], "'\(mark)'")
        }
        // The same text without the mark has no sentence end to use: it breaks at a space near the budget instead.
        let plain = NarrationChunkPlanner.articlePlan(String(repeating: "word ", count: 14) + "end" + String(repeating: " more", count: 30))
        XCTAssertEqual(plain.chunks.map(\.boundary), [.whitespace, .whitespace, .hard])
        XCTAssertEqual(lengths(of: plain), [179, 40, 4])
    }

    func testANewlineEndsAChunkWhenTheTextIsChunkedBeforeNormalizing() {
        // The planner normalizes first, which turns newlines into spaces; the chunker itself still treats one as a sentence end.
        let text = String(repeating: "word ", count: 14) + "end\n" + String(repeating: " more", count: 30)
        let slices = RenderedSpeechChunker.sourceSlices(from: text)
        XCTAssertEqual(slices.map(\.startOffset), [0, 74, 220])
        XCTAssertEqual(slices.map(\.slice.sourceLength), [74, 146, 4])
        XCTAssertEqual(slices.map(\.slice.boundary), [.sentence, .whitespace, .hard])
    }

    /// "。" and "…" are not sentence ends for the chunker (it knows only . ! ? ; : and newline), and Japanese or
    /// Chinese text has no spaces, so such text can only be cut hard at the budget.
    func testTextWithoutLatinPunctuationOrSpacesIsCutHardAtTheBudget() {
        let cjk = String(repeating: "今日は天気がいいです。", count: 30)
        let cjkPlan = NarrationChunkPlanner.articlePlan(cjk)
        XCTAssertEqual(cjkPlan.chunks.map(\.boundary), [.hard, .hard])
        XCTAssertEqual(lengths(of: cjkPlan), [180, 150])
        XCTAssertEqual(cjkPlan.chunks.map(\.text), [String(cjk.prefix(180)), String(cjk.dropFirst(180))])

        let ellipses = String(repeating: "あ…", count: 130)
        let ellipsisPlan = NarrationChunkPlanner.articlePlan(ellipses)
        XCTAssertEqual(ellipsisPlan.chunks.map(\.boundary), [.hard, .hard])
        XCTAssertEqual(lengths(of: ellipsisPlan), [180, 80])
        XCTAssertEqual(ellipsisPlan.chunks.map(\.text), [String(ellipses.prefix(180)), String(ellipses.dropFirst(180))])
    }

    // MARK: A budget other than the default

    func testABudgetOtherThanTheDefaultCutsAtThatBudget() {
        let letters = String(repeating: "a", count: 250)
        let plan = NarrationChunkPlanner.articlePlan(letters, budget: 120)
        assertPlan(plan, [
            (0, 120, .hard, String(repeating: "a", count: 120)),
            (120, 120, .hard, String(repeating: "a", count: 120)),
            (240, 10, .hard, String(repeating: "a", count: 10)),
        ], "250 letters at budget 120")
        XCTAssertEqual(plan.identity, NarrationChunkPlanner.articlePlan(letters).identity, "the budget is not part of the identity")
    }

    func testThePlayersPlanUsesTheSameBudgetForThePrefaceAndTheArticle() {
        let preface = String(repeating: "b", count: 130)
        let article = String(repeating: "a", count: 250)
        let spoken = NarrationChunkPlanner.spokenPlan(
            spokenText: preface + article, articleText: article, articleSpokenStart: 130, budget: 120
        )
        XCTAssertEqual(spoken.chunks.map(\.startOffset), [0, 120, 130, 250, 370])
        XCTAssertEqual(spoken.chunks.map(\.sourceLength), [120, 10, 120, 120, 10])
        XCTAssertEqual(spoken.chunks.map(\.articleIndex), [nil, nil, 0, 1, 2])
        XCTAssertEqual(spoken.articleIdentity, NarrationChunkPlanner.articlePlan(article).identity)
    }

    /// With room for 300 a chunk of 80 characters is still too short to be worth ending at a sentence, so a sentence
    /// that ends at character 72 does not end a chunk; at the default budget the same sentence does.
    func testAShortFirstSentenceEndsAChunkAtTheDefaultBudgetButNotAtAWiderOne() {
        let text = "This opening sentence is about seventy characters long and then it ends. "
            + String(repeating: "and then plain words continue without any punctuation at all ", count: 8)
        let narrow = NarrationChunkPlanner.articlePlan(text)
        XCTAssertEqual(lengths(of: narrow), [72, 180, 180, 125, 3])
        XCTAssertEqual(narrow.chunks.first?.boundary, .sentence)
        let wide = NarrationChunkPlanner.articlePlan(text, budget: 300)
        XCTAssertEqual(lengths(of: wide), [298, 259, 3])
        XCTAssertEqual(wide.chunks.map(\.boundary), [.whitespace, .whitespace, .hard])
    }

    // MARK: Without article text

    func testWithoutArticleTextEveryChunkIsAnArticleChunkAndNoIdentityIsClaimed() {
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: String(repeating: "a", count: 181), articleText: nil, articleSpokenStart: 0)
        XCTAssertEqual(spoken.chunks.map(\.startOffset), [0, 180])
        XCTAssertEqual(spoken.chunks.map(\.sourceLength), [180, 1])
        XCTAssertEqual(spoken.chunks.map(\.articleIndex), [0, 1], "the spoken text is the article")
        XCTAssertNil(spoken.articleIdentity, "the caller identifies it by its own source text")
        XCTAssertEqual(spoken.articleSpokenStart, 0)

        // A start offset means nothing without an article to start after.
        let started = NarrationChunkPlanner.spokenPlan(spokenText: "Overview. x", articleText: nil, articleSpokenStart: 10)
        XCTAssertEqual(started.chunks.map(\.articleIndex), [0])
        XCTAssertEqual(started.chunks.map(\.sourceLength), [11])
        XCTAssertEqual(started.articleSpokenStart, 0)
    }

    func testAnArticleThatIsNotTheSpokenTextMatchesNoPreparedChunk() {
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: String(repeating: "a", count: 181), articleText: "different", articleSpokenStart: 0)
        XCTAssertEqual(spoken.chunks.map(\.sourceLength), [180, 1])
        XCTAssertEqual(spoken.chunks.map(\.articleIndex), [nil, nil])
        XCTAssertNil(spoken.articleIdentity)
    }
}
