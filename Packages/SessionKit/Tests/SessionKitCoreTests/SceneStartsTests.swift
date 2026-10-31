import Foundation
import SessionKit
import XCTest

final class SceneStartsTests: XCTestCase {
    private func scene(
        _ order: Int, start: Int?, title: String? = nil, summary: String? = "A recap.",
        eligibility: PortableSceneEligibility = .eligible, transcriptSegmentId: String? = nil
    ) -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(order)", order: order, title: title, summaryText: summary,
            eligibility: eligibility,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: start, transcriptSegmentId: transcriptSegmentId),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: (start ?? 0) + 1_000)
        )
    }

    private func point(_ source: Int, _ recipient: Int?, _ confidence: ResolvedListeningMapConfidence) -> ResolvedListeningMapPoint {
        ResolvedListeningMapPoint(
            id: "point-\(source)", sourceMediaTimeMs: source, recipientMediaTimeMs: recipient,
            confidence: confidence, evidenceIds: []
        )
    }

    private func projection(
        version: String = "shared-map-scene-starts.v1", points: [ResolvedListeningMapPoint] = []
    ) -> ResolvedListeningMapProjection {
        ResolvedListeningMapProjection(id: "projection", itemId: "item", algorithmVersion: version, points: points, intervals: [])
    }

    private func exact(_ scenes: [PortableListeningMapScene]) -> SceneStarts {
        SceneStarts(scenes: scenes, projection: projection(version: "episode-projection.exact-edition.v1"))
    }

    func testExactEditionUsesSourceTimesInSceneOrderAndPreservesMissingStarts() {
        let starts = exact([scene(2, start: nil), scene(1, start: 5_000), scene(0, start: 0)])
        XCTAssertEqual(starts.scenes.map(\.id), ["scene-0", "scene-1", "scene-2"])
        XCTAssertEqual(starts.sceneStarts, [0, 5_000, nil])
    }

    func testOnlyNonemptyEqualExactOrVerifiedPointsAllowIdentityFallback() {
        let scenes = [scene(0, start: 5_000)]
        let identity = SceneStarts(scenes: scenes, projection: projection(points: [
            point(0, 0, .exactEdition), point(10_000, 10_000, .verified)
        ]))
        XCTAssertEqual(identity.sceneStarts, [5_000], "An unlisted start uses the identity fallback")
        for points in [
            [], [point(0, 0, .approximate)], [point(0, 0, .unresolved)],
            [point(0, 1, .verified)], [point(0, nil, .exactEdition)],
            [point(0, 0, .verified), point(10_000, 10_001, .exactEdition)]
        ] {
            XCTAssertEqual(SceneStarts(scenes: scenes, projection: projection(points: points)).sceneStarts, [nil])
        }
        XCTAssertEqual(SceneStarts(scenes: scenes, projection: nil).sceneStarts, [nil])
        // A concrete placement wins even if the other points permit the identity fallback.
        let placed = SceneStarts(scenes: scenes, projection: projection(points: [point(5_000, 7_000, .verified)]))
        XCTAssertEqual(placed.sceneStarts, [7_000])
    }

    func testForwardRefusesAnUnplacedDestinationInsteadOfSkippingIt() {
        let scenes = [scene(0, start: 0), scene(1, start: 5_000), scene(2, start: 10_000)]
        let starts = SceneStarts(scenes: scenes, projection: projection(points: [
            point(0, 1_000, .verified), point(10_000, 11_000, .verified)
        ]))
        XCTAssertEqual(starts.sceneStarts, [1_000, nil, 11_000])
        XCTAssertNil(starts.skimPlan(direction: .forward, at: 2_000, durationMs: 20_000))
    }

    func testForwardUsesNextSceneAndLastSceneUsesDurationWithoutDestinationScene() throws {
        let starts = exact([scene(1, start: 5_000), scene(0, start: 0)])
        let next = try XCTUnwrap(starts.skimPlan(direction: .forward, at: 4_999, durationMs: nil))
        XCTAssertEqual(next.currentScene.id, "scene-0")
        XCTAssertEqual(next.summaryScene.id, "scene-0")
        XCTAssertEqual(next.destinationSceneId, "scene-1")
        XCTAssertEqual(next.destinationMediaTimeMs, 5_000)
        let last = try XCTUnwrap(starts.skimPlan(direction: .forward, at: 5_000, durationMs: 12_345))
        XCTAssertEqual(last.currentScene.id, "scene-1")
        XCTAssertEqual(last.summaryScene.id, "scene-1")
        XCTAssertNil(last.destinationSceneId)
        XCTAssertEqual(last.destinationMediaTimeMs, 12_345)
        XCTAssertNil(starts.skimPlan(direction: .forward, at: 5_000, durationMs: nil))
    }

    func testBackwardFromFirstSceneIsRefused() {
        let starts = exact([scene(0, start: 0), scene(1, start: 5_000)])
        XCTAssertNil(starts.skimPlan(direction: .backward, at: 0, durationMs: 10_000))
        XCTAssertNil(starts.skimPlan(direction: .backward, at: 4_999, durationMs: 10_000))
    }

    func testBackwardSummarizesPreviousSceneAndReturnsToCurrentSceneStart() throws {
        let starts = exact([scene(0, start: 0), scene(1, start: 5_000), scene(2, start: 10_000)])
        let plan = try XCTUnwrap(starts.skimPlan(direction: .backward, at: 10_500, durationMs: nil))
        XCTAssertEqual(plan.currentScene.id, "scene-2")
        XCTAssertEqual(plan.summaryScene.id, "scene-1")
        XCTAssertEqual(plan.destinationSceneId, "scene-2")
        XCTAssertEqual(plan.destinationMediaTimeMs, 10_000)
    }

    func testIneligibleOrEmptySummaryRefusesEitherDirection() {
        let cases: [(PortableSceneEligibility, String?)] = [
            (.excluded, "A recap."), (.unknown, "A recap."),
            (.eligible, nil), (.eligible, ""), (.eligible, " \n\t ")
        ]
        for (eligibility, summary) in cases {
            let starts = exact([scene(0, start: 0, summary: summary, eligibility: eligibility), scene(1, start: 5_000)])
            XCTAssertNil(starts.skimPlan(direction: .forward, at: 0, durationMs: 10_000))
            XCTAssertNil(starts.skimPlan(direction: .backward, at: 5_000, durationMs: 10_000))
        }
        let starts = exact([scene(0, start: 0, summary: " \nRecap.\t")])
        XCTAssertNotNil(starts.skimPlan(direction: .forward, at: 0, durationMs: 10_000))
    }

    func testChaptersDropUnplacedScenesSortByStartAndPreserveDisplayFields() {
        let scenes = [
            scene(3, start: nil), scene(1, start: 5_000, title: " \n ", summary: "\t "),
            scene(0, start: 0, title: "  Opening\n", summary: " Recap.\n", transcriptSegmentId: "segment"),
            scene(2, start: 10_000), scene(4, start: 15_000)
        ]
        let starts = SceneStarts(scenes: scenes, projection: projection(points: [
            point(0, 9_000, .verified), point(5_000, 2_000, .verified), point(15_000, 16_000, .verified)
        ]))
        XCTAssertEqual(starts.sceneStarts, [9_000, 2_000, nil, nil, 16_000])
        XCTAssertEqual(starts.chapters, [
            MediaTimelineChapter(id: "scene-1", title: "Scene 2", startMs: 2_000, transcriptSegmentId: "scene-1"),
            MediaTimelineChapter(id: "scene-0", title: "Opening", description: "Recap.", startMs: 9_000, transcriptSegmentId: "segment"),
            MediaTimelineChapter(id: "scene-4", title: "Scene 5", description: "A recap.", startMs: 16_000, transcriptSegmentId: "scene-4")
        ])
        XCTAssertTrue(SceneStarts(scenes: scenes, projection: nil).chapters.isEmpty)
        XCTAssertEqual(starts.scenes, scenes.sorted { $0.order < $1.order }, "Shared scene values are not rewritten")
    }

    func testNoCurrentSceneRefusesSkim() {
        for starts in [exact([]), exact([scene(0, start: 5_000)]), exact([scene(0, start: nil)])] {
            XCTAssertNil(starts.skimPlan(direction: .forward, at: 0, durationMs: 10_000))
            XCTAssertNil(starts.skimPlan(direction: .backward, at: 0, durationMs: 10_000))
        }
    }
    // MARK: Text items (#1471)

    private func textScene(
        _ order: Int, start: Int?, end: Int?, summary: String? = "A recap.", eligibility: PortableSceneEligibility = .eligible
    ) -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(order)", order: order, title: nil, summaryText: summary, eligibility: eligibility,
            startAnchor: PortableAnchorEvidence(anchorType: .text, startChar: start, endChar: start.map { $0 + 5 }),
            endAnchor: PortableAnchorEvidence(anchorType: .text, startChar: end.map { $0 - 5 }, endChar: end)
        )
    }

    func testTextScenesTakeStartsAndEndsFromCharacterPositionsInSceneOrder() {
        let starts = SceneStarts(textScenes: [
            textScene(2, start: 900, end: 1_400), textScene(0, start: 0, end: 400), textScene(1, start: 400, end: 900)
        ])
        XCTAssertEqual(starts.scenes.map(\.id), ["scene-0", "scene-1", "scene-2"])
        XCTAssertEqual(starts.sceneStarts, [0, 400, 900])
        XCTAssertEqual(starts.sceneEnds, [400, 900, 1_400])
    }

    func testTextScenesNeverReadMediaTimes() {
        // A media-anchored scene has no character start, so a text item never mistakes milliseconds for characters.
        let starts = SceneStarts(textScenes: [scene(0, start: 5_000), scene(1, start: 9_000)])
        XCTAssertEqual(starts.sceneStarts, [nil, nil])
        XCTAssertEqual(starts.sceneEnds, [nil, nil])
        XCTAssertNil(starts.skimPlan(direction: .forward, at: 6_000, durationMs: 20_000))
    }

    func testTextSceneNeighbouringInputsStayUnplacedOrUnknown() {
        let rows: [(start: Int?, end: Int?, expectedStart: Int?, expectedEnd: Int?, why: String)] = [
            (nil, 100, nil, nil, "no start: unplaced, and its end is not trusted"),
            (-1, 100, nil, nil, "a negative start is not a position"),
            (50, nil, 50, nil, "no end: placed with the end unknown"),
            (50, 50, 50, nil, "an empty span is an unknown end"),
            (50, 49, 50, nil, "an end before the start is an unknown end"),
            (0, 1, 0, 1, "the shortest span"),
        ]
        for row in rows {
            let starts = SceneStarts(textScenes: [textScene(0, start: row.start, end: row.end)])
            XCTAssertEqual(starts.sceneStarts, [row.expectedStart], row.why)
            XCTAssertEqual(starts.sceneEnds, [row.expectedEnd], row.why)
        }
    }

    func testSkimPlansOnTextUseCharactersForThePositionAndTheTextLength() throws {
        let starts = SceneStarts(textScenes: [
            textScene(0, start: 0, end: 400, summary: "First."),
            textScene(1, start: 400, end: 900, summary: "Second."),
            textScene(2, start: 900, end: 1_400, summary: "Third.")
        ])
        let forward = try XCTUnwrap(starts.skimPlan(direction: .forward, at: 120, durationMs: 1_400))
        XCTAssertEqual(forward.summaryScene.id, "scene-0")
        XCTAssertEqual(forward.destinationSceneId, "scene-1")
        XCTAssertEqual(forward.destinationMediaTimeMs, 400, "a character offset, not milliseconds")

        let atBoundary = try XCTUnwrap(starts.skimPlan(direction: .forward, at: 400, durationMs: 1_400))
        XCTAssertEqual(atBoundary.currentScene.id, "scene-1", "the character that starts a scene belongs to it")

        let last = try XCTUnwrap(starts.skimPlan(direction: .forward, at: 1_000, durationMs: 1_400))
        XCTAssertNil(last.destinationSceneId)
        XCTAssertEqual(last.destinationMediaTimeMs, 1_400, "past the last chapter is the end of the text")

        let back = try XCTUnwrap(starts.skimPlan(direction: .backward, at: 1_000, durationMs: 1_400))
        XCTAssertEqual(back.summaryScene.id, "scene-1")
        XCTAssertEqual(back.destinationSceneId, "scene-2")
        XCTAssertEqual(back.destinationMediaTimeMs, 900)

        XCTAssertNil(starts.skimPlan(direction: .backward, at: 120, durationMs: 1_400), "nothing before the first chapter")
    }

    func testTextSkimRefusesAnUnplacedDestinationAndAnUnusableSummary() {
        let gap = SceneStarts(textScenes: [
            textScene(0, start: 0, end: 400), textScene(1, start: nil, end: nil), textScene(2, start: 900, end: 1_400)
        ])
        XCTAssertNil(gap.skimPlan(direction: .forward, at: 100, durationMs: 1_400))
        for (eligibility, summary) in [(PortableSceneEligibility.excluded, "A recap."), (.eligible, " \n ")] as [(PortableSceneEligibility, String)] {
            let starts = SceneStarts(textScenes: [
                textScene(0, start: 0, end: 400, summary: summary, eligibility: eligibility), textScene(1, start: 400, end: 900)
            ])
            XCTAssertNil(starts.skimPlan(direction: .forward, at: 100, durationMs: 900))
        }
    }

    func testTextScenesFeedTheChaptersAndSummarySpansTheItemPageUses() {
        let starts = SceneStarts(textScenes: [textScene(0, start: 0, end: 400), textScene(1, start: 400, end: 900)])
        XCTAssertEqual(starts.chapters.map(\.startMs), [0, 400])
        XCTAssertEqual(starts.summarySpans.map(\.endMs), [400, 900])
    }
}
