import SessionKit
import SessionKitSharing
import XCTest

/// #3461: a long PDF's scene map must still fit one packet, or sharing it fails with "the map has N scenes".
final class TextSceneSummaryPacketLimitTests: XCTestCase {
    func testTheSceneCapLeavesRoomUnderThePacketLimit() {
        XCTAssertLessThan(TextSceneSummaryPlanner.maximumScenes, ListeningMapPacket.maximumScenes)
    }
}
