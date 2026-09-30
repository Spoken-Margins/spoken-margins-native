import Foundation
import XCTest
@testable import SessionKit

/// #312: the player, background preparation and assembly take an article's chunks from one plan.
final class NarrationChunkPlannerTests: XCTestCase {
    private let article = (1...9).map {
        "Sentence \($0) of the article reports 91.1% across 7,494 decisions, which the chunker must split carefully."
    }.joined(separator: " ")
    private let preface = "Overview. The paper studies evaluation agents and how they choose their tools.\n\n"

    /// What background preparation used before #312; existing prepared audio was saved with it.
    private var legacyBackgroundPlan: [(Int, Int, String)] {
        RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(article), maxCharacters: RenderedSpeechChunker.spokenCostBudget)
            .map { ($0.startOffset, $0.slice.sourceLength, $0.slice.text) }
    }

    func testArticlePlanIsTheChunkingPreparedAudioWasSavedWith() {
        let plan = NarrationChunkPlanner.articlePlan(article)
        XCTAssertEqual(plan.chunks.map { $0.startOffset }, legacyBackgroundPlan.map(\.0))
        XCTAssertEqual(plan.chunks.map { $0.text }, legacyBackgroundPlan.map(\.2))
        XCTAssertEqual(plan.chunks.map(\.index), Array(plan.chunks.indices))
    }

    func testPlayerPlanWithoutAPrefaceIsTheArticlePlan() {
        let plan = NarrationChunkPlanner.articlePlan(article)
        let spoken = NarrationChunkPlanner.spokenPlan(
            spokenText: SpeechTextNormalizer.normalizeWithSourceOffsets(article).text, articleText: article, articleSpokenStart: 0
        )
        XCTAssertEqual(spoken.articleIdentity, plan.identity)
        XCTAssertEqual(spoken.chunks.map { $0.articleIndex }, plan.chunks.map { $0.index })
        XCTAssertEqual(spoken.chunks.map { $0.startOffset }, plan.chunks.map { $0.startOffset })
        XCTAssertEqual(spoken.chunks.map { $0.text }, plan.chunks.map { $0.text })
        XCTAssertEqual(spoken.chunks.map { $0.boundary }, plan.chunks.map { $0.boundary })
    }

    func testPlayerPlanWithAPrefaceHasTheArticlePlanAfterIt() {
        let plan = NarrationChunkPlanner.articlePlan(article)
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(preface + article)
        let start = projection.spokenCharacterOffset(atOrAfterSourceOffset: preface.count)
        let spoken = NarrationChunkPlanner.spokenPlan(spokenText: projection.text, articleText: article, articleSpokenStart: start)
        XCTAssertEqual(spoken.articleIdentity, plan.identity)
        let prefaceChunks = spoken.chunks.filter { $0.articleIndex == nil }
        let articleChunks = spoken.chunks.filter { $0.articleIndex != nil }
        XCTAssertFalse(prefaceChunks.isEmpty)
        XCTAssertTrue(prefaceChunks.allSatisfy { $0.startOffset < start }, "preface chunks stay in the preface")
        XCTAssertEqual(articleChunks.map { $0.articleIndex }, plan.chunks.map { $0.index })
        XCTAssertEqual(articleChunks.map { $0.startOffset - start }, plan.chunks.map { $0.startOffset })
        XCTAssertEqual(articleChunks.map { $0.text }, plan.chunks.map { $0.text })
        // The spoken plan covers the spoken text without gaps.
        for pair in zip(spoken.chunks, spoken.chunks.dropFirst()) {
            XCTAssertEqual(pair.0.startOffset + pair.0.sourceLength, pair.1.startOffset)
        }
    }

    func testAChangedArticleMatchesNoPreparedAudio() {
        let spoken = NarrationChunkPlanner.spokenPlan(
            spokenText: SpeechTextNormalizer.normalize(article + " An added sentence."), articleText: article, articleSpokenStart: 0
        )
        XCTAssertNil(spoken.articleIdentity)
        XCTAssertTrue(spoken.chunks.allSatisfy { $0.articleIndex == nil })
        XCTAssertNotEqual(NarrationChunkPlanner.identity(ofArticle: article), NarrationChunkPlanner.identity(ofArticle: article + " "))
    }
}
