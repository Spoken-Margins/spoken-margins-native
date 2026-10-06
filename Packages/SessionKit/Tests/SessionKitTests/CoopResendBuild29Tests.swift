import Foundation
import SessionKit
import ShippedSessionKit
import XCTest

/// The database Build 29 opens (#858): a Margin marked with the names a later packet gave it still
/// decodes there, and one that arrived once is stored exactly as before.
final class CoopResendBuild29Tests: XCTestCase {
    func testBuild29StillReadsAMarginKnownByTwoPackets() throws {
        var margin = SessionKit.ImportedCommentaryInterjection(
            id: "m", layerId: "l", packageScopedId: "margin-0001", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            anchorEvidence: SessionKit.PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000), approvedTranscript: "words"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let once = try encoder.encode(margin)
        XCTAssertFalse(String(decoding: once, as: UTF8.self).contains("alsoSharedAs"))

        margin.alsoSharedAs = [MarginPacketIdentity(packageDigest: "digest", packageScopedId: "margin-0002")]
        let stored = try encoder.encode(margin)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("alsoSharedAs"))
        let build29 = try JSONDecoder().decode(ShippedSessionKit.ImportedCommentaryInterjection.self, from: stored)
        XCTAssertEqual(build29.id, "m")
        XCTAssertEqual(build29.approvedTranscript, "words")
        XCTAssertEqual(build29.packageScopedId, "margin-0001")
    }
}
