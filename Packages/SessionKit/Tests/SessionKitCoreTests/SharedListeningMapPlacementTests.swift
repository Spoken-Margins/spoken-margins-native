import Foundation
import SessionKit
import XCTest

/// The decision half of placing a friend's shared map on a different edition (#481).
/// The acoustic half runs on macOS in `SharedListeningMapResolverTests`.
final class SharedListeningMapPlacementTests: XCTestCase {
    private let landmarks = [20_000, 100_000, 180_000, 260_000].enumerated().map { index, start in
        EpisodeFingerprintLandmark(
            id: "landmark-\(index)", order: index,
            sourceMediaStartMs: start, sourceMediaEndMs: start + 11_000, anchorMediaTimeMs: start,
            continuityEpoch: 0, trigger: .downloadedPreparation, provenance: .downloadedSourceReference,
            signatureAssetId: "signature-\(index)"
        )
    }

    private func proposal(starts: [Int?]) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: "friend-map", createdAt: Date(timeIntervalSince1970: 0), generator: "test",
            scenes: starts.enumerated().map { index, start in
                PortableListeningMapScene(
                    id: "scene-\(index)", order: index, title: index == 1 ? "The interview" : nil,
                    eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: start),
                    endAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: (start ?? 0) + 1_000)
                )
            }
        )
    }

    private func queries(_ proposal: PortableListeningMapProposalArtifact) throws -> [SharedListeningMapPlacement.SceneQuery] {
        try SharedListeningMapPlacement.sceneQueries(proposal: proposal, landmarks: landmarks).get()
    }

    private func placed(_ ms: Int, _ evidenceClass: AnchorResolutionEvidenceClass = .fused) -> ImportedAnchorResolution {
        ImportedAnchorResolution(evidenceClass: evidenceClass, localMediaTimeMs: ms, confidence: 0.95)
    }

    private func decide(
        _ proposal: PortableListeningMapProposalArtifact,
        _ resolutions: [String: ImportedAnchorResolution]
    ) throws -> SharedListeningMapPlacement.Outcome {
        SharedListeningMapPlacement.decide(
            proposal: proposal, queries: try queries(proposal), resolutions: resolutions,
            projectionId: "shared-projection", itemId: "my-episode", recipientEditionSHA256: "my-bytes",
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testEachSceneStartIsBracketedByTheLandmarksAroundIt() throws {
        let queries = try queries(proposal(starts: [0, 60_000, 220_000, 300_000]))
        XCTAssertEqual(queries.map { $0.landmarks.map(\.id) }, [
            ["landmark-0"],
            ["landmark-0", "landmark-1"],
            ["landmark-2", "landmark-3"],
            ["landmark-3"]
        ])
        XCTAssertEqual(queries[1].landmarks.map {
            SharedListeningMapPlacement.anchorOffsetMs(sceneStartMs: queries[1].senderStartMs, landmark: $0)
        }, [40_000, -40_000])
    }

    func testAMapWhoseStartsAllPlaceBecomesAProjectionOnTheRecipientsTimes() throws {
        let map = proposal(starts: [0, 25_000, 185_000])
        let outcome = try decide(map, [
            "scene-0": placed(0, .acousticVerified),
            "scene-1": placed(25_000),
            "scene-2": placed(192_000)
        ])
        guard case .placed(let projection) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(projection.proposalId, "friend-map")
        XCTAssertEqual(projection.itemId, "my-episode")
        XCTAssertEqual(projection.recipientEditionSHA256, "my-bytes")
        XCTAssertEqual(projection.algorithmVersion, SharedListeningMapPlacement.algorithmVersion)
        XCTAssertEqual(projection.projectedRecipientTime(for: 0), 0)
        XCTAssertEqual(projection.projectedRecipientTime(for: 25_000), 25_000)
        XCTAssertEqual(projection.projectedRecipientTime(for: 185_000), 192_000)
        XCTAssertNil(projection.projectedRecipientTime(for: 150_000), "Only scene starts are placed")
        XCTAssertEqual(map, proposal(starts: [0, 25_000, 185_000]), "The portable proposal is never rewritten")
    }

    func testOneUnplacedSceneKeepsTheWholeMapUnused() throws {
        let outcome = try decide(proposal(starts: [0, 25_000, 185_000]), [
            "scene-0": placed(0),
            "scene-1": ImportedAnchorResolution(evidenceClass: .ambiguous, isAmbiguous: true),
            "scene-2": placed(192_000)
        ])
        XCTAssertEqual(outcome, .notPlaced(.init(sceneId: "scene-1", sceneLabel: "Scene 2 (The interview)", reason: .ambiguous)))
        guard case .notPlaced(let refusal) = outcome else { return }
        XCTAssertEqual(
            refusal.listenerReason,
            "Scene 2 (The interview) matched more than one place in your copy, or your copy changes inside it."
        )
    }

    func testOnlyDirectAcousticEvidencePlacesAScene() throws {
        for weak in [AnchorResolutionEvidenceClass.timestampFallback, .mapInterpolated, .transcriptVerified, .unresolved] {
            let outcome = try decide(proposal(starts: [0, 25_000]), [
                "scene-0": placed(0),
                "scene-1": placed(25_000, weak)
            ])
            XCTAssertEqual(outcome, .notPlaced(.init(sceneId: "scene-1", sceneLabel: "Scene 2 (The interview)", reason: .unresolved)), "\(weak)")
        }
        let missing = try decide(proposal(starts: [0, 25_000]), ["scene-0": placed(0)])
        XCTAssertEqual(missing, .notPlaced(.init(sceneId: "scene-1", sceneLabel: "Scene 2 (The interview)", reason: .unresolved)))
    }

    func testStartsThatDoNotIncreaseAreRefused() throws {
        let outcome = try decide(proposal(starts: [0, 25_000, 185_000]), [
            "scene-0": placed(0),
            "scene-1": placed(195_000),
            "scene-2": placed(192_000)
        ])
        XCTAssertEqual(outcome, .notPlaced(.init(sceneId: "scene-2", sceneLabel: "Scene 3", reason: .outOfOrder)))
    }

    func testScenesWithoutTimesOrEvidenceAreRefusedBeforeMatching() {
        XCTAssertEqual(
            SharedListeningMapPlacement.sceneQueries(proposal: proposal(starts: [0, nil]), landmarks: landmarks),
            .failure(.init(sceneId: "scene-1", sceneLabel: "Scene 2 (The interview)", reason: .missingStartTime))
        )
        XCTAssertEqual(
            SharedListeningMapPlacement.sceneQueries(proposal: proposal(starts: [0]), landmarks: []),
            .failure(.init(sceneId: "scene-0", sceneLabel: "Scene 1", reason: .noEvidence))
        )
        XCTAssertEqual(
            SharedListeningMapPlacement.sceneQueries(proposal: proposal(starts: []), landmarks: landmarks),
            .failure(.init(sceneId: nil, sceneLabel: nil, reason: .noScenes))
        )
    }

    func testASharedMapNeverReplacesTheListenersOwnMap() throws {
        let outcome = try decide(proposal(starts: [0, 25_000]), ["scene-0": placed(0), "scene-1": placed(25_000)])
        guard case .placed(let projection) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(SharedListeningMapPlacement.activation([outcome], listenerProposalIds: []).projection, projection)
        let mine = SharedListeningMapPlacement.activation([outcome], listenerProposalIds: ["episode-map-proposal-mine"])
        XCTAssertNil(mine.projection)
        XCTAssertNil(mine.refusal, "The listener's own map is in use, so nothing is wrong")
    }

    func testTheFirstPlacedFriendsMapStaysAndARefusalShowsOnlyWhenNoneIsInUse() throws {
        let placedOutcome = try decide(proposal(starts: [0, 25_000]), ["scene-0": placed(0), "scene-1": placed(25_000)])
        let refused = try decide(proposal(starts: [0, 25_000]), ["scene-0": placed(0)])
        let otherPlaced = SharedListeningMapPlacement.Outcome.placed(ResolvedListeningMapProjection(
            id: "second-friend", itemId: "my-episode", proposalId: "second-map", points: [], intervals: []))
        let both = SharedListeningMapPlacement.activation([refused, placedOutcome, otherPlaced], listenerProposalIds: [])
        XCTAssertEqual(both.projection?.proposalId, "friend-map")
        XCTAssertNil(both.refusal)
        let none = SharedListeningMapPlacement.activation([refused], listenerProposalIds: [])
        XCTAssertNil(none.projection)
        XCTAssertEqual(none.refusal?.reason, .unresolved)
        let nothing = SharedListeningMapPlacement.activation([], listenerProposalIds: [])
        XCTAssertNil(nothing.projection)
        XCTAssertNil(nothing.refusal)
        let inUse = SharedListeningMapPlacement.activation(
            [placedOutcome, otherPlaced], listenerProposalIds: [], activeProposalId: "second-map")
        XCTAssertEqual(inUse.projection?.proposalId, "second-map", "The map in use stays while it still places")
    }

    /// The landmarks' audio covers 20-31 s, 100-111 s, 180-191 s and 260-271 s. A scene start
    /// outside all of them is refused even when both neighbouring landmarks matched and agree.
    func testASceneStartIsPlacedOnlyInsideALandmarksAudio() throws {
        // Codex audit on babc304: insert 7 s at 40 s and cut 7 s at 80-87 s. Both landmarks
        // around a scene at 60 s stay put and agree, but the scene now starts at 67 s.
        XCTAssertEqual(try decide(proposal(starts: [0, 60_000]), [
            "scene-0": placed(0, .acousticVerified), "scene-1": placed(60_000)
        ]).refusal, .init(sceneId: "scene-1", sceneLabel: "Scene 2 (The interview)", reason: .uncovered))
        // Tail: inside the last landmark's audio is placed, past it is refused.
        let covered = try decide(proposal(starts: [0, 25_000, 185_000, 265_000]), [
            "scene-0": placed(0, .acousticVerified), "scene-1": placed(25_000),
            "scene-2": placed(192_000), "scene-3": placed(272_000, .acousticVerified)
        ])
        guard case .placed(let projection) = covered else { return XCTFail("\(covered)") }
        XCTAssertEqual(projection.projectedRecipientTime(for: 265_000), 272_000)
        XCTAssertEqual(try decide(proposal(starts: [0, 25_000, 185_000, 280_000]), [
            "scene-0": placed(0, .acousticVerified), "scene-1": placed(25_000),
            "scene-2": placed(192_000), "scene-3": placed(287_000, .acousticVerified)
        ]).refusal, .init(sceneId: "scene-3", sceneLabel: "Scene 4", reason: .uncovered))
        // Head: before the first landmark's audio is refused.
        XCTAssertEqual(try decide(proposal(starts: [0, 10_000, 25_000]), [
            "scene-0": placed(7_000), "scene-1": placed(17_000, .acousticVerified), "scene-2": placed(32_000)
        ]).refusal, .init(sceneId: "scene-1", sceneLabel: "Scene 2 (The interview)", reason: .uncovered))
        // The first scene at 0:00 starts at 0:00 on any copy.
        let preRoll = try decide(proposal(starts: [0, 25_000]), ["scene-0": placed(7_000, .acousticVerified), "scene-1": placed(32_000)])
        guard case .placed(let headProjection) = preRoll else { return XCTFail("\(preRoll)") }
        XCTAssertEqual(headProjection.projectedRecipientTime(for: 0), 0)
        XCTAssertEqual(headProjection.projectedRecipientTime(for: 25_000), 32_000)
        // An exact edition needs no coverage: every byte is the sender's.
        guard case .placed = try decide(proposal(starts: [0, 60_000]), [
            "scene-0": placed(0, .exactEdition), "scene-1": placed(60_000, .exactEdition)
        ]) else { return XCTFail("exact edition") }
    }
}
