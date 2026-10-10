import Foundation
import SessionKit
import XCTest

final class MarginShareProvenanceTests: XCTestCase {
    func testSessionAndMarginBothParticipateWithoutExposingLocalIDs() throws {
        let session = "session-item-11111111-1111-4111-8111-111111111111"
        let first = try XCTUnwrap(MarginShareProvenance.token(sessionId: session, interjectionId: "ij-001"))
        XCTAssertEqual(first, MarginShareProvenance.token(sessionId: session.uppercased(), interjectionId: "ij-001"))
        XCTAssertNotEqual(first, MarginShareProvenance.token(sessionId: session, interjectionId: "ij-002"))
        XCTAssertNotEqual(first, MarginShareProvenance.token(sessionId: "22222222-2222-4222-8222-222222222222", interjectionId: "ij-001"))
        XCTAssertFalse(first.contains("ij-001"))
        XCTAssertEqual(first.count, 64)
        XCTAssertNil(MarginShareProvenance.token(sessionId: "old-sequential-session", interjectionId: "ij-001"))
        XCTAssertNil(MarginShareProvenance.token(sessionId: session, interjectionId: ""))
    }

    func testRepresentationIDNeighbourTable() {
        let token = String(repeating: "a", count: 64)
        let valid = "sm-origin-v1-\(token)-text"
        let inputs: [(String, String?)] = [
            (valid, token), ("sm-origin-v1-\(token)-original", token), ("sm-origin-v1-\(token)-cleaned", token),
            (valid.uppercased(), nil), (" \(valid)\n", nil), (valid + "!", nil), ("", nil),
            (String(repeating: "a", count: 50_000), nil), ("representation-0001-text", nil),
            (valid.replacingOccurrences(of: "sm-origin", with: "sm-orіgin"), nil),
            ("sm-origin-v1-\(token)-te\u{301}xt", nil),
            ("sm-origin-v1-\(String(repeating: "A", count: 64))-text", nil),
            ("sm-origin-v1-\(token)-", nil), ("sm-origin-v1-\(token)-text-extra", nil)
        ]
        for (input, expected) in inputs { XCTAssertEqual(MarginShareProvenance.token(representationID: input), expected) }
        XCTAssertEqual(MarginShareProvenance.representationID(token: nil, kind: "text", fallback: "old"), "old")
    }
}
