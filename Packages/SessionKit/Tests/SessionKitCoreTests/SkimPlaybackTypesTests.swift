import Foundation
import SessionKit
import XCTest

/// The Skim plan and resolution values the app's Skim bridge passes around, moved out of the app (#318).
final class SkimPlaybackTypesTests: XCTestCase {
    private func plan(destination: Int = 90_000) -> ResolvedSkimPlaybackPlan {
        ResolvedSkimPlaybackPlan(
            direction: .forward, itemId: "item-1", originMediaTimeMs: 10_000,
            summarySceneId: "scene-2", destinationSceneId: "scene-3",
            destinationMediaTimeMs: destination, summaryAssetId: "asset-2",
            summaryAudioURL: URL(fileURLWithPath: "/tmp/summary.m4a")
        )
    }

    private func proposal(sceneCount: Int) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: "map", createdAt: Date(timeIntervalSince1970: 0), generator: "test",
            scenes: (0..<sceneCount).map { index in
                PortableListeningMapScene(
                    id: "scene-\(index)", order: index, eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 1_000),
                    endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 1_000 + 500)
                )
            }
        )
    }

    private func projection() -> ResolvedListeningMapProjection {
        ResolvedListeningMapProjection(id: "projection", itemId: "item-1", points: [], intervals: [])
    }

    private func context(
        projection: ResolvedListeningMapProjection?, proposal: PortableListeningMapProposalArtifact?, text: Bool
    ) -> SkimResourceContext {
        SkimResourceContext(itemId: "item-1", projection: projection, proposal: proposal, assets: [], usesTextPositions: text)
    }

    func testLandingKeepsEverythingButTheDestinationTime() {
        let original = plan()
        let moved = original.landing(at: 120_000)
        XCTAssertEqual(moved.destinationMediaTimeMs, 120_000)
        XCTAssertEqual(original.destinationMediaTimeMs, 90_000, "the original plan is a value and does not change")
        XCTAssertEqual(moved.direction, original.direction)
        XCTAssertEqual(moved.itemId, original.itemId)
        XCTAssertEqual(moved.originMediaTimeMs, original.originMediaTimeMs)
        XCTAssertEqual(moved.summarySceneId, original.summarySceneId)
        XCTAssertEqual(moved.destinationSceneId, original.destinationSceneId)
        XCTAssertEqual(moved.summaryAssetId, original.summaryAssetId)
        XCTAssertEqual(moved.summaryAudioURL, original.summaryAudioURL)
    }

    /// An item has Skim when it has a resolved map (a media projection, or a text item's own character positions) and
    /// a proposal that holds at least one scene. Every neighbouring combination of the three inputs, one row each.
    func testHasMapNeedsAPlacedMapAndAProposalWithScenes() {
        let withScenes = proposal(sceneCount: 2)
        let table: [(String, SkimResourceContext, Bool)] = [
            ("media projection and a proposal", context(projection: projection(), proposal: withScenes, text: false), true),
            ("text positions and a proposal, no projection", context(projection: nil, proposal: withScenes, text: true), true),
            ("text positions and a projection", context(projection: projection(), proposal: withScenes, text: true), true),
            ("no projection and not a text item", context(projection: nil, proposal: withScenes, text: false), false),
            ("a projection but no proposal", context(projection: projection(), proposal: nil, text: false), false),
            ("text positions but no proposal", context(projection: nil, proposal: nil, text: true), false),
            ("a proposal with no scenes", context(projection: projection(), proposal: proposal(sceneCount: 0), text: false), false),
            ("a text item whose proposal has no scenes", context(projection: nil, proposal: proposal(sceneCount: 0), text: true), false),
            ("nothing at all", context(projection: nil, proposal: nil, text: false), false)
        ]
        for (name, context, expected) in table {
            XCTAssertEqual(context.hasMap, expected, name)
        }
    }

    func testResolutionReportsItsDestinationAndWhySkimCannotRun() throws {
        let scene = try XCTUnwrap(proposal(sceneCount: 1).scenes.first)
        let request = SkimSummaryRequest(
            itemId: "item-1", proposalId: "map", assetID: "asset-voice-2", scene: scene, destinationMediaTimeMs: 45_000
        )
        let ready = SkimResolution.ready(plan(destination: 90_000))
        XCTAssertEqual(ready.destinationMediaTimeMs, 90_000)
        XCTAssertNil(ready.unavailableReason)

        let needs = SkimResolution.needsSummaryAudio(request)
        XCTAssertEqual(needs.destinationMediaTimeMs, 45_000)
        XCTAssertNil(needs.unavailableReason)

        for reason in [SkimUnavailableReason.noSource, .noMap, .noSceneSummary, .suppliedSummaryMissing] {
            let unavailable = SkimResolution.unavailable(reason)
            XCTAssertNil(unavailable.destinationMediaTimeMs, "\(reason) has no place to go")
            XCTAssertEqual(unavailable.unavailableReason, reason)
        }
    }
}
