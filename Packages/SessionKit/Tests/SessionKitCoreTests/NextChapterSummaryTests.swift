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

    // MARK: the chapter row's button next to Skim (#1628)

    func testForwardSlotIsNeverEmptyWhenTheItemHasSkim() {
        func forward(_ isAvailable: Bool, row: Bool, canForward: Bool) -> Rule.ChapterRowControl {
            Rule.forwardControl(isAvailable: isAvailable, skimRowShown: row, canSkimForward: canForward)
        }
        // chapters + a Skim row with forward enabled: Skim is the one forward control
        XCTAssertEqual(forward(true, row: true, canForward: true), .skim)
        // the end of the map, a feed chapter still ahead: Next chapter takes the slot, marked as standing in for Skim
        // so a plain jump never looks like a Skim (#2185)
        XCTAssertEqual(forward(true, row: true, canForward: false), .nextChapterInSkimSlot)
        // the last chapter and no scene ahead: the slot stays, dimmed (#1666: no empty slot)
        XCTAssertEqual(forward(false, row: true, canForward: false), .skimDisabled)
        // the last chapter with a summary still ahead inside it
        XCTAssertEqual(forward(false, row: true, canForward: true), .skim)
        // chapters only, a missing or unready map, or an article: no Skim row, Next chapter as before
        XCTAssertEqual(forward(true, row: false, canForward: false), .nextChapter)
        XCTAssertEqual(forward(false, row: false, canForward: false), .hidden)
        // forward can't be pressed without the row (a stale flag must not draw Skim)
        XCTAssertEqual(forward(true, row: false, canForward: true), .nextChapter)
        XCTAssertEqual(forward(false, row: false, canForward: true), .hidden)
    }

    func testBackwardSlotKeepsItsPlaceWhenTheItemHasSkim() {
        XCTAssertEqual(Rule.backwardControl(skimRowShown: true, canSkimBackward: true), .skim)
        XCTAssertEqual(Rule.backwardControl(skimRowShown: true, canSkimBackward: false), .skimDisabled)
        XCTAssertEqual(Rule.backwardControl(skimRowShown: false, canSkimBackward: false), .hidden)
        XCTAssertEqual(Rule.backwardControl(skimRowShown: false, canSkimBackward: true), .hidden)
    }
    // MARK: text chapters count characters (#1471)

    func testTextChapterSummaryLandsOnTheChapterStartWithinACharacterTolerance() {
        let tolerance = Rule.alignmentToleranceChars
        // A scene that starts where the chapter does reads its summary, then lands at the chapter start.
        XCTAssertEqual(
            Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: 4_000, summaryLandsAtMs: 4_000, tolerance: tolerance),
            .summaryThenJump(landingMs: 4_000))
        XCTAssertEqual(
            Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: 4_000, summaryLandsAtMs: 4_000 + tolerance, tolerance: tolerance),
            .summaryThenJump(landingMs: 4_000))
        // 900 characters apart is far past a boundary; 900 ms would have counted as aligned, so the unit matters.
        XCTAssertEqual(
            Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: 4_000, summaryLandsAtMs: 4_900, tolerance: tolerance),
            .jump)
        XCTAssertEqual(
            Rule.press(playing: nil, hasNextChapter: true, nextChapterStartMs: 4_000, summaryLandsAtMs: 4_900),
            .summaryThenJump(landingMs: 4_000), "the default stays the media tolerance")
    }

    func testASecondPressOnTextSkipsTheSummaryOnlyWhenItHeadsForTheNextChapter() {
        let tolerance = Rule.alignmentToleranceChars
        let heading = Rule.PlayingSummary(direction: .forward, landsAtMs: 4_000)
        let elsewhere = Rule.PlayingSummary(direction: .forward, landsAtMs: 4_900)
        XCTAssertEqual(Rule.press(playing: heading, hasNextChapter: true, nextChapterStartMs: 4_000, summaryLandsAtMs: nil, tolerance: tolerance), .skipSummary)
        XCTAssertEqual(Rule.press(playing: elsewhere, hasNextChapter: true, nextChapterStartMs: 4_000, summaryLandsAtMs: nil, tolerance: tolerance), .unavailable)
        XCTAssertTrue(Rule.isAvailable(playing: heading, hasNextChapter: true, nextChapterStartMs: 4_000, tolerance: tolerance))
        XCTAssertFalse(Rule.isAvailable(playing: elsewhere, hasNextChapter: true, nextChapterStartMs: 4_000, tolerance: tolerance))
    }
}
