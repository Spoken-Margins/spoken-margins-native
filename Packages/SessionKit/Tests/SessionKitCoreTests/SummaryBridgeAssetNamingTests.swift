import XCTest
@testable import SessionKit

final class SummaryBridgeAssetNamingTests: XCTestCase {
    private func id(proposal: String = "map", scene: String = "scene-1", supplied: String?, item: String = "item-1") -> String {
        SummaryBridgeAssetNaming.assetID(itemId: item, proposalId: proposal, sceneId: scene,
                                         suppliedAssetId: supplied, generatedVoiceKey: "gen")
    }

    func testIdsTheCutLeavesAloneKeepTheirOldNames() {
        XCTAssertEqual(id(supplied: "voice-1"), "summary-bridge-item-1-map-scene-1-supplied-voice-1")
        XCTAssertEqual(id(supplied: nil), "summary-bridge-item-1-map-scene-1-gen")
        XCTAssertNil(SummaryBridgeAssetNaming.legacyAssetID(itemId: "item-1", proposalId: "map", sceneId: "scene-1", suppliedAssetId: "voice-1"))
        let ninetySix = String(repeating: "a", count: 96)
        XCTAssertEqual(SummaryBridgeAssetNaming.component(ninetySix), ninetySix)
    }

    func testVoiceIdsThatDifferOnlyInDroppedCharactersGetDifferentNames() {
        let first = id(supplied: "v\u{E9}"), second = id(supplied: "v\u{E8}")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, "summary-bridge-item-1-map-scene-1-supplied-v--x01cb79234ea25c63")
        XCTAssertEqual(second, "summary-bridge-item-1-map-scene-1-supplied-v--xbd7b67070c70bd88")
    }

    func testSceneAndProposalIdsThatDifferOnlyInDroppedCharactersGetDifferentNames() {
        XCTAssertNotEqual(id(scene: "s\u{E9}", supplied: "v"), id(scene: "s\u{E8}", supplied: "v"))
        XCTAssertNotEqual(id(proposal: "p\u{E9}", supplied: "v"), id(proposal: "p\u{E8}", supplied: "v"))
    }

    func testIdsThatShareTheirFirstNinetySixCharactersGetDifferentNames() {
        let stem = String(repeating: "a", count: 96)
        let first = id(supplied: stem + "-one"), second = id(supplied: stem + "-two")
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, id(supplied: stem), "an id cut to 96 must not take the name of the 96-character id itself")
    }

    func testAHashedComponentStaysInsideTheSafeAlphabetAndNinetySixCharacters() {
        for value in ["caf\u{E9}", "", String(repeating: "\u{E9}", count: 300), String(repeating: "b", count: 200), "a b/c:d"] {
            let part = SummaryBridgeAssetNaming.component(value)
            XCTAssertLessThanOrEqual(part.count, 96, value.prefix(12).debugDescription)
            XCTAssertEqual(part, PodcastAnchorEvidencePaths.safeComponent(part), "already safe: \(part)")
        }
    }

    func testTheNewNameIsStableAcrossBuilds() {
        // A saved voice is found again by this exact name, so it is pinned as a literal.
        XCTAssertEqual(id(proposal: "p19-map-996", scene: "p19-scene-1", supplied: "p19-author-caf\u{E9}", item: "p19-author-996"),
                       "summary-bridge-p19-author-996-p19-map-996-p19-scene-1-supplied-p19-author-caf--xdcdf2af036ee7b5f")
    }

    func testTheOldNameOfAVoiceSavedBeforeThisChangeIsStillComputable() {
        XCTAssertEqual(
            SummaryBridgeAssetNaming.legacyAssetID(itemId: "p19-author-996", proposalId: "p19-map-996", sceneId: "p19-scene-1",
                                                   suppliedAssetId: "p19-author-caf\u{E9}"),
            "summary-bridge-p19-author-996-p19-map-996-p19-scene-1-supplied-p19-author-caf-")
        // Both clashing ids map to the one old name, which is why the new name is tried first.
        XCTAssertEqual(
            SummaryBridgeAssetNaming.legacyAssetID(itemId: "i", proposalId: "m", sceneId: "s", suppliedAssetId: "v\u{E9}"),
            SummaryBridgeAssetNaming.legacyAssetID(itemId: "i", proposalId: "m", sceneId: "s", suppliedAssetId: "v\u{E8}"))
    }
}
