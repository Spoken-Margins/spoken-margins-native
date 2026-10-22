import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

/// Opening a mapped item reads the saved summaries once, not once per scene (#2255).
final class SummaryBridgeInventoryTests: XCTestCase {
    private func scene(_ index: Int, summary: String? = "A short recap.", eligibility: PortableSceneEligibility = .eligible) -> PortableListeningMapScene {
        PortableListeningMapScene(
            id: "scene-\(index)", order: index, title: "Scene \(index)", summaryText: summary,
            eligibility: eligibility,
            startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 60_000),
            endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: (index + 1) * 60_000)
        )
    }

    private func proposal(_ scenes: [PortableListeningMapScene]) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(id: "map", createdAt: Date(), generator: "test", scenes: scenes)
    }

    private func bridge(_ sceneId: String, integrity: OfflineAssetIntegrity = .valid) -> OwnedOfflineAsset {
        OwnedOfflineAsset(id: "bridge-\(sceneId)", itemId: "episode", category: .summaryBridge,
                          relativePath: "SummaryBridges/\(sceneId).caf", byteCount: 10, isReproducible: true, integrity: integrity)
    }

    func testAMapWhoseSummariesAreAllSavedReadsTheAssetTableOnceAndNeedsNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        // A 77-minute episode's worth of scenes, every summary saved, as on the owner's phone.
        let scenes = (0..<40).map { scene($0) }
        for scene in scenes { try store.saveOwnedOfflineAsset(bridge(scene.id)) }
        for index in 0..<200 {
            try store.saveOwnedOfflineAsset(OwnedOfflineAsset(id: "other-\(index)", category: .summaryBridge,
                                                              relativePath: "Other/\(index).caf", byteCount: 1, isReproducible: true))
        }
        var assetReads = 0
        let inventory = try XCTUnwrap(SummaryBridgeInventory.read(
            loadProposal: { proposal(scenes) },
            loadAssets: { assetReads += 1; return try store.loadOwnedOfflineAssets() }
        ))
        var checked: [String] = []
        let needed = inventory.scenesNeedingAudio(assetID: { "bridge-\($0.id)" }, fileExists: { checked.append($0); return true })
        XCTAssertEqual(assetReads, 1, "the asset table is read once for the whole map, not once per scene")
        XCTAssertEqual(needed.map(\.id), [])
        XCTAssertEqual(checked.count, 40, "each saved summary's file is checked once")
    }

    func testOnlyScenesWithoutAUsableSavedSummaryNeedPreparing() throws {
        let scenes = [
            scene(0),                                   // saved and on disk
            scene(1),                                   // saved, file gone
            scene(2),                                   // saved but stale
            scene(3),                                   // never saved
            scene(4, summary: "  \n"),                  // no summary text: still reported as not prepared
            scene(5, summary: nil),
            scene(6, eligibility: .excluded),           // not skimmable: never prepared
            scene(7, eligibility: .unknown),
        ]
        let assets = [bridge("scene-0"), bridge("scene-1"), bridge("scene-2", integrity: .stale),
                      bridge("scene-4"), bridge("scene-5"), bridge("scene-6")]
        let inventory = SummaryBridgeInventory(proposal: proposal(scenes), assets: assets)
        let needed = inventory.scenesNeedingAudio(assetID: { "bridge-\($0.id)" }, fileExists: { $0 != "SummaryBridges/scene-1.caf" })
        XCTAssertEqual(needed.map(\.id), ["scene-1", "scene-2", "scene-3", "scene-4", "scene-5"])
    }

    func testAnIDTheCurrentVoiceDoesNotMatchNeedsPreparing() {
        // The asset ID names the voice, so a summary saved in another voice is not this voice's summary.
        let inventory = SummaryBridgeInventory(proposal: proposal([scene(0)]), assets: [bridge("scene-0")])
        let needed = inventory.scenesNeedingAudio(assetID: { "bridge-\($0.id)-kitten" }, fileExists: { _ in true })
        XCTAssertEqual(needed.map(\.id), ["scene-0"])
    }

    func testNoMapOrNoEligibleSceneLeavesTheAssetTableUnread() throws {
        var assetReads = 0
        let loadAssets: () throws -> [OwnedOfflineAsset] = { assetReads += 1; return [] }
        XCTAssertNil(try SummaryBridgeInventory.read(loadProposal: { nil }, loadAssets: loadAssets))
        let inventory = try XCTUnwrap(SummaryBridgeInventory.read(
            loadProposal: { proposal([scene(0, eligibility: .excluded)]) }, loadAssets: loadAssets))
        XCTAssertEqual(inventory.scenesNeedingAudio(assetID: { $0.id }, fileExists: { _ in true }).map(\.id), [])
        XCTAssertEqual(assetReads, 0)
    }
}
