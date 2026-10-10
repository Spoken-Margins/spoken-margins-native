import Foundation
import SessionKit
import XCTest

/// Next chapter reads the summary of the chapter being skipped (#569).
final class NextChapterSummaryTests: XCTestCase {
    private typealias Rule = NextChapterSummaryRule

    private func scene(_ order: Int, start: Int, summary: String? = "What this chapter covered.") -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(order)", order: order, title: "Ch. \(order + 1)", summaryText: summary,
            eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start + 1_000)
        )
    }

    private func starts(_ scenes: [PortableListeningMapScene]) -> SceneStarts {
        SceneStarts(scenes: scenes, projection: ResolvedListeningMapProjection(
            id: "projection", itemId: "item", algorithmVersion: "episode-projection.exact-edition.v1",
            points: [], intervals: []
        ))
    }

    private var mapOnly: SceneStarts {
        starts([scene(0, start: 0), scene(1, start: 60_000), scene(2, start: 180_000, summary: nil)])
    }

    /// The press as the app makes it on a map-only item: the next chapter is the next scene.
    private func press(at ms: Int, playing: Rule.PlayingSummary? = nil) -> NextChapterPress {
        let next = mapOnly.chapters.first { $0.startMs > ms }
        let plan = mapOnly.skimPlan(direction: .forward, at: ms, durationMs: 300_000)
        return Rule.press(
            playing: playing, hasNextChapter: next != nil,
            nextChapterStartMs: next?.startMs, summaryLandsAtMs: plan?.destinationMediaTimeMs
        )
    }

    func testSummarisedChapterPlaysItsSummaryThenLandsAtTheNextChapterStart() {
        XCTAssertEqual(press(at: 75_000), .summaryThenJump(landingMs: 180_000))
        XCTAssertEqual(mapOnly.skimPlan(direction: .forward, at: 75_000, durationMs: 300_000)?.summaryScene.id, "scene-1",
                       "The summary read is the chapter being left, not the one landed on")
    }

    func testSecondPressDuringTheSummarySkipsItAndIsStillOffered() {
        let summary = Rule.PlayingSummary(direction: .forward, landsAtMs: 180_000)
        XCTAssertEqual(press(at: 75_000, playing: summary), .skipSummary)
        XCTAssertTrue(Rule.isAvailable(playing: summary, hasNextChapter: true, nextChapterStartMs: 180_000))
    }

    func testChapterWithoutASummaryKeepsThePlainJump() {
        let unsummarised = starts([scene(0, start: 0, summary: nil), scene(1, start: 60_000)])
        let plan = unsummarised.skimPlan(direction: .forward, at: 5_000, durationMs: 300_000)
        XCTAssertEqual(Rule.press(
            playing: nil, hasNextChapter: true, nextChapterStartMs: 60_000, summaryLandsAtMs: plan?.destinationMediaTimeMs
        ), .jump)
    }

    func testTextChaptersAndUnalignedFeedChaptersKeepThePlainJump() {
        XCTAssertEqual(Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: nil, summaryLandsAtMs: 60_000),
                       .jump, "A text chapter has no media start to line a summary up with")
        XCTAssertEqual(Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: 600_000, summaryLandsAtMs: 120_000),
                       .jump, "A feed chapter that spans several scenes doesn't read one scene's summary")
        XCTAssertEqual(Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: 60_400, summaryLandsAtMs: 60_000),
                       .summaryThenJump(landingMs: 60_400), "A near-aligned scene still lands at the chapter start")
    }

    /// Feed chapters at 0 and 600 s, scenes every 120 s: a Skim forward heading to 120 s is not
    /// a Next chapter summary, so Next chapter must not "skip" it to 120 s, mid-chapter.
    func testSkimForwardToASceneInsideTheChapterIsNotSkippedByNextChapter() {
        let skim = Rule.PlayingSummary(direction: .forward, landsAtMs: 120_000)
        XCTAssertEqual(Rule.press(playing: skim, hasNextChapter: true, nextChapterStartMs: 600_000, summaryLandsAtMs: nil), .unavailable)
        XCTAssertFalse(Rule.isAvailable(playing: skim, hasNextChapter: true, nextChapterStartMs: 600_000))
    }

    func testNoNextChapterOrABackwardSummaryIsUnavailable() {
        XCTAssertEqual(press(at: 200_000), .unavailable)
        let back = Rule.PlayingSummary(direction: .backward, landsAtMs: 180_000)
        XCTAssertEqual(press(at: 75_000, playing: back), .unavailable)
        XCTAssertFalse(Rule.isAvailable(playing: back, hasNextChapter: true, nextChapterStartMs: 180_000))
        XCTAssertFalse(Rule.isAvailable(playing: nil, hasNextChapter: false, nextChapterStartMs: nil))
        XCTAssertTrue(Rule.isAvailable(playing: nil, hasNextChapter: true, nextChapterStartMs: nil))
    }
}
