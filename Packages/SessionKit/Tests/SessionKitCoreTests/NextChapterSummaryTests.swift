import Foundation
import SessionKit
import XCTest

/// Next chapter reads the summary of the chapter being skipped (#569).
final class NextChapterSummaryTests: XCTestCase {
    private func scene(_ order: Int, start: Int, summary: String? = "What this chapter covered.") -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(order)", order: order, title: "Ch. \(order + 1)", summaryText: summary,
            eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start + 1_000)
        )
    }

    private var starts: SceneStarts {
        SceneStarts(
            scenes: [scene(0, start: 0), scene(1, start: 60_000), scene(2, start: 180_000, summary: nil)],
            projection: ResolvedListeningMapProjection(
                id: "projection", itemId: "item", algorithmVersion: "episode-projection.exact-edition.v1",
                points: [], intervals: []
            )
        )
    }

    /// The press as the app makes it on a map-only item: the next chapter is the next scene.
    private func press(at ms: Int, playing: SkimDirection? = nil) -> NextChapterPress {
        let next = starts.chapters.first { $0.startMs > ms }
        let plan = starts.skimPlan(direction: .forward, at: ms, durationMs: 300_000)
        return NextChapterSummaryRule.press(
            playingSummary: playing, hasNextChapter: next != nil,
            nextChapterStartMs: next?.startMs, summaryLandsAtMs: plan?.destinationMediaTimeMs
        )
    }

    func testSummarisedChapterPlaysItsSummaryThenLandsAtTheNextChapterStart() {
        XCTAssertEqual(press(at: 75_000), .summaryThenJump(landingMs: 180_000))
        XCTAssertEqual(starts.skimPlan(direction: .forward, at: 75_000, durationMs: 300_000)?.summaryScene.id, "scene-1",
                       "The summary read is the chapter being left, not the one landed on")
    }

    func testSecondPressDuringTheSummarySkipsItAndIsStillOffered() {
        XCTAssertEqual(press(at: 75_000, playing: .forward), .skipSummary)
        XCTAssertTrue(NextChapterSummaryRule.isAvailable(playingSummary: .forward, hasNextChapter: false))
    }

    func testChapterWithoutASummaryKeepsThePlainJump() {
        let unsummarised = SceneStarts(
            scenes: [scene(0, start: 0, summary: nil), scene(1, start: 60_000)],
            projection: ResolvedListeningMapProjection(
                id: "projection", itemId: "item", algorithmVersion: "episode-projection.exact-edition.v1",
                points: [], intervals: []
            )
        )
        let plan = unsummarised.skimPlan(direction: .forward, at: 5_000, durationMs: 300_000)
        XCTAssertEqual(NextChapterSummaryRule.press(
            playingSummary: nil, hasNextChapter: true, nextChapterStartMs: 60_000, summaryLandsAtMs: plan?.destinationMediaTimeMs
        ), .jump)
    }

    func testTextChaptersAndUnalignedFeedChaptersKeepThePlainJump() {
        XCTAssertEqual(NextChapterSummaryRule.press(
            playingSummary: nil, hasNextChapter: true, nextChapterStartMs: nil, summaryLandsAtMs: 60_000
        ), .jump, "A text chapter has no media start to line a summary up with")
        XCTAssertEqual(NextChapterSummaryRule.press(
            playingSummary: nil, hasNextChapter: true, nextChapterStartMs: 30_000, summaryLandsAtMs: 60_000
        ), .jump, "A feed chapter that ends mid-scene doesn't read the scene's summary")
        XCTAssertEqual(NextChapterSummaryRule.press(
            playingSummary: nil, hasNextChapter: true, nextChapterStartMs: 60_400, summaryLandsAtMs: 60_000
        ), .summaryThenJump(landingMs: 60_400), "A near-aligned scene still lands at the chapter start")
    }

    func testNoNextChapterOrABackwardSummaryIsUnavailable() {
        XCTAssertEqual(press(at: 200_000), .unavailable)
        XCTAssertEqual(press(at: 75_000, playing: .backward), .unavailable)
        XCTAssertFalse(NextChapterSummaryRule.isAvailable(playingSummary: .backward, hasNextChapter: true))
        XCTAssertFalse(NextChapterSummaryRule.isAvailable(playingSummary: nil, hasNextChapter: false))
        XCTAssertTrue(NextChapterSummaryRule.isAvailable(playingSummary: nil, hasNextChapter: true))
    }
}
