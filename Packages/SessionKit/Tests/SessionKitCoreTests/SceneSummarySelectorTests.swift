import Foundation
import SessionKit
import XCTest

/// Podcast Now shows the summary of the scene under the playhead (#1629).
final class SceneSummarySelectorTests: XCTestCase {
    private func scene(
        _ order: Int, start: Int?, end: Int?, summary: String? = nil,
        eligibility: PortableSceneEligibility = .eligible
    ) -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(order)", order: order, title: "Scene title \(order)", summaryText: summary ?? "Summary \(order).",
            eligibility: eligibility,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: end)
        )
    }

    private func exactSpans(_ scenes: [PortableListeningMapScene]) -> [SceneSummarySpan] {
        SceneStarts(
            scenes: scenes,
            projection: ResolvedListeningMapProjection(
                id: "p", itemId: "item", algorithmVersion: "episode-projection.exact-edition.v1", points: [], intervals: [])
        ).summarySpans
    }

    private let contiguous: [PortableListeningMapScene] = [
        PortableListeningMapScene(id: "scene-0", order: 0, title: "One", summaryText: "Summary 0.", eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000)),
        PortableListeningMapScene(id: "scene-1", order: 1, title: "Two", summaryText: "Summary 1.", eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 180_000)),
        PortableListeningMapScene(id: "scene-2", order: 2, title: "Three", summaryText: "Summary 2.", eligibility: .eligible,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 180_000),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 300_000)),
    ]

    func testBoundariesBelongToTheSceneThatStartsThere() {
        let spans = exactSpans(contiguous)
        let at = { (ms: Int) in SceneSummarySelector.summary(at: ms, in: spans) }
        XCTAssertEqual(at(0), "Summary 0.")
        XCTAssertEqual(at(59_999), "Summary 0.")
        XCTAssertEqual(at(60_000), "Summary 1.")
        XCTAssertEqual(at(179_999), "Summary 1.")
        XCTAssertEqual(at(180_000), "Summary 2.")
        XCTAssertEqual(at(299_999), "Summary 2.")
        XCTAssertNil(at(300_000), "The last scene's own end is the end of its summary")
    }

    func testSeekingEitherWayNeverLeavesAnEarlierSceneSummaryOnScreen() {
        let spans = exactSpans(contiguous)
        // Forward, back, and across several scenes at once, as Back, Skim and the timeline do.
        let path = [10_000, 200_000, 70_000, 5_000, 290_000, 61_000]
        XCTAssertEqual(path.map { SceneSummarySelector.summary(at: $0, in: spans) },
            ["Summary 0.", "Summary 2.", "Summary 1.", "Summary 0.", "Summary 2.", "Summary 1."])
    }

    func testBeforeTheFirstSceneAndAfterTheLastShowNothing() {
        let spans = exactSpans([scene(0, start: 30_000, end: 90_000)])
        XCTAssertNil(SceneSummarySelector.summary(at: 0, in: spans))
        XCTAssertNil(SceneSummarySelector.summary(at: 29_999, in: spans))
        XCTAssertEqual(SceneSummarySelector.summary(at: 30_000, in: spans), "Summary 0.")
        XCTAssertNil(SceneSummarySelector.summary(at: 90_000, in: spans))
        XCTAssertNil(SceneSummarySelector.summary(at: 10_000_000, in: spans))
    }

    func testAGapBetweenScenesShowsNothingInsteadOfTheScenePastItsEnd() {
        let spans = exactSpans([scene(0, start: 0, end: 60_000), scene(1, start: 120_000, end: 200_000)])
        XCTAssertEqual(SceneSummarySelector.summary(at: 59_999, in: spans), "Summary 0.")
        XCTAssertNil(SceneSummarySelector.summary(at: 60_000, in: spans))
        XCTAssertNil(SceneSummarySelector.summary(at: 119_999, in: spans))
        XCTAssertEqual(SceneSummarySelector.summary(at: 120_000, in: spans), "Summary 1.")
    }

    func testASceneWithoutAUsableSummaryHidesTheOneBeforeIt() {
        var scenes = contiguous
        scenes[1] = scene(1, start: 60_000, end: 180_000, summary: "  \n ")
        scenes.append(scene(3, start: 300_000, end: 400_000, summary: "An ad read.", eligibility: .excluded))
        scenes.append(scene(4, start: 400_000, end: 500_000, summary: "Unknown.", eligibility: .unknown))
        let spans = exactSpans(scenes)
        XCTAssertEqual(SceneSummarySelector.summary(at: 59_999, in: spans), "Summary 0.")
        XCTAssertNil(SceneSummarySelector.summary(at: 60_000, in: spans), "Whitespace is not a summary")
        XCTAssertNil(SceneSummarySelector.summary(at: 100_000, in: spans))
        XCTAssertEqual(SceneSummarySelector.summary(at: 180_000, in: spans), "Summary 2.")
        XCTAssertNil(SceneSummarySelector.summary(at: 350_000, in: spans), "Excluded scenes keep their summary off Now")
        XCTAssertNil(SceneSummarySelector.summary(at: 450_000, in: spans))
    }

    func testSummaryIsTrimmed() {
        let spans = exactSpans([scene(0, start: 0, end: 10_000, summary: "  Padded.\n")])
        XCTAssertEqual(SceneSummarySelector.summary(at: 5, in: spans), "Padded.")
    }

    func testAMissingOrBackwardsEndRunsUntilTheNextSceneStarts() {
        let spans = exactSpans([
            scene(0, start: 0, end: nil), scene(1, start: 50_000, end: 40_000), scene(2, start: 90_000, end: 90_000),
        ])
        XCTAssertEqual(SceneSummarySelector.summary(at: 49_999, in: spans), "Summary 0.")
        XCTAssertEqual(SceneSummarySelector.summary(at: 50_000, in: spans), "Summary 1.")
        XCTAssertEqual(SceneSummarySelector.summary(at: 89_999, in: spans), "Summary 1.")
        XCTAssertEqual(SceneSummarySelector.summary(at: 3_600_000, in: spans), "Summary 2.")
    }

    func testOverlappingScenesUseTheLatestStartedOne() {
        let spans = exactSpans([scene(0, start: 0, end: 100_000), scene(1, start: 40_000, end: 80_000)])
        XCTAssertEqual(SceneSummarySelector.summary(at: 39_999, in: spans), "Summary 0.")
        XCTAssertEqual(SceneSummarySelector.summary(at: 40_000, in: spans), "Summary 1.")
        XCTAssertNil(SceneSummarySelector.summary(at: 80_000, in: spans), "Past the later scene's end, not back to the earlier one")
    }

    func testUnplacedScenesAreLeftOutAndSpansFollowTimeNotProposalOrder() {
        let spans = exactSpans([scene(2, start: nil, end: nil), scene(1, start: 60_000, end: 120_000), scene(0, start: 0, end: 60_000)])
        XCTAssertEqual(spans.map(\.sceneId), ["scene-0", "scene-1"])
        XCTAssertEqual(SceneSummarySelector.summary(at: 90_000, in: spans), "Summary 1.")
    }

    func testProjectionMovesSummariesToTheListenersCopy() {
        // The recipient's copy has a 30 s ad up front, so source time 0 is 30 s into their audio.
        let points = [
            ResolvedListeningMapPoint(id: "a", sourceMediaTimeMs: 0, recipientMediaTimeMs: 30_000, confidence: .verified, evidenceIds: []),
            ResolvedListeningMapPoint(id: "b", sourceMediaTimeMs: 60_000, recipientMediaTimeMs: 90_000, confidence: .verified, evidenceIds: []),
            ResolvedListeningMapPoint(id: "c", sourceMediaTimeMs: 120_000, recipientMediaTimeMs: 150_000, confidence: .verified, evidenceIds: []),
        ]
        let projection = ResolvedListeningMapProjection(
            id: "p", itemId: "item", algorithmVersion: "shared-map-scene-starts.v1", points: points, intervals: [])
        let spans = SceneStarts(scenes: Array(contiguous.prefix(2)), projection: projection).summarySpans
        XCTAssertNil(SceneSummarySelector.summary(at: 10_000, in: spans), "The ad is before scene 0 on this copy")
        XCTAssertEqual(SceneSummarySelector.summary(at: 30_000, in: spans), "Summary 0.")
        XCTAssertEqual(SceneSummarySelector.summary(at: 89_999, in: spans), "Summary 0.")
        XCTAssertEqual(SceneSummarySelector.summary(at: 90_000, in: spans), "Summary 1.")
    }

    func testAMapThatCannotBePlacedOrIsMissingShowsNothing() {
        XCTAssertNil(SceneSummarySelector.summary(at: 5_000, in: []))
        let unplaced = SceneStarts(scenes: contiguous, projection: nil).summarySpans
        XCTAssertEqual(unplaced, [])
        XCTAssertNil(SceneSummarySelector.summary(at: 5_000, in: unplaced))
    }
}
