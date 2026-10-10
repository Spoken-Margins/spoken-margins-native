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
}
