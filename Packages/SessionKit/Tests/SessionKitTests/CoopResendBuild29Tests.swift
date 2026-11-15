import Foundation
import SessionKit
import SessionKitPersistence
import ShippedSessionKit
import XCTest

/// The database Build 29 opens (#858): a Margin marked with the names a later packet gave it still
/// decodes there, including optional capture provenance that the old reader ignores. The row is the
/// one the store wrote, read from the file (#4309).
final class CoopResendBuild29Tests: XCTestCase {
    func testBuild29StillReadsAMarginKnownByTwoPackets() throws {
        let path = try StoredRecordFile.temporaryPath(for: self)
        let store = try SQLiteSessionStore(path: path)
        var margin = SessionKit.ImportedCommentaryInterjection(
            id: "m", layerId: "l", packageScopedId: "margin-0001", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            anchorEvidence: SessionKit.PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000), approvedTranscript: "words",
            shareProvenance: MarginShareProvenance.token(sessionId: UUID().uuidString, interjectionId: "ij-001")
        )
        try store.saveImportedCommentaryInterjection(margin)
        let once = try StoredRecordFile.payload(path: path, kind: "imported_commentary_interjection", id: "m")
        XCTAssertFalse(String(decoding: once, as: UTF8.self).contains("alsoSharedAs"))

        margin.alsoSharedAs = [MarginPacketIdentity(packageDigest: "digest", packageScopedId: "margin-0002")]
        try store.saveImportedCommentaryInterjection(margin)
        let stored = try StoredRecordFile.payload(path: path, kind: "imported_commentary_interjection", id: "m")
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("alsoSharedAs"))
        let build29 = try StoredRecordFile.decodeInShippedBuild(ShippedSessionKit.ImportedCommentaryInterjection.self, from: stored)
        XCTAssertEqual(build29.id, "m")
        XCTAssertEqual(build29.approvedTranscript, "words")
        XCTAssertEqual(build29.packageScopedId, "margin-0001")
    }
}
