import Foundation
import SessionKit
import XCTest

/// The sender's run-up length (#4171): the write rule, the clamp a reader applies, and how an imported Margin keeps it.
/// The packet side, with the real writer and Build 29's reader, is `LeadInPacketTests` (Mac only).
final class SenderLeadInTests: XCTestCase {
    func testTheWriteRuleTable() {
        let d = SenderLeadIn.defaultMs
        // (chosen, previous, written)
        let table: [(Int?, Int?, Int?)] = [
            (nil, nil, nil),            // nothing chosen, never shared with a length: the packet an older build writes
            (d, nil, nil),              // the default chosen outright is the default
            (60_000, nil, 60_000),
            (5_000, nil, 5_000),
            (120_000, 120_000, 120_000), // the same length as last time still travels
            (60_000, d, 60_000),
            (d, 60_000, d),             // taking a length back is said out loud
            (nil, 60_000, d),           // so is dropping back to the default by choosing nothing
            (d, d, nil),                // an earlier share at 20 s needs no key either
            (d, 0, d),                  // 0 is a length: coming back from it is said out loud
            (0, nil, 0),
            (999_999, nil, 300_000),    // a writer never exceeds what a reader accepts
            (-5, nil, 0),
            (d, 999_999, d),
            (nil, -3, d),               // -3 clamps to 0, which is not the default
        ]
        for (chosen, previous, written) in table {
            XCTAssertEqual(SenderLeadIn.valueToWrite(chosen: chosen, previous: previous), written,
                           "chosen \(String(describing: chosen)), previous \(String(describing: previous))")
        }
    }

    func testTheClampIsTheReadersRange() {
        XCTAssertEqual(SenderLeadIn.range, 0...300_000)
        for (input, expected) in [(-1, 0), (0, 0), (1, 1), (20_000, 20_000), (300_000, 300_000), (300_001, 300_000), (Int.max, 300_000), (Int.min, 0)] {
            XCTAssertEqual(SenderLeadIn.clamped(input), expected, "\(input)")
        }
    }

    func testAnImportedMarginClampsWhatThePacketAsked() {
        func margin(_ ms: Int?) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(
                id: "m", layerId: "l", packageScopedId: "p", createdAt: Date(timeIntervalSince1970: 0),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), approvedTranscript: "words",
                senderLeadInMs: ms)
        }
        XCTAssertNil(margin(nil).senderLeadInMs, "A packet from a build without the setting keeps each run-up's default")
        XCTAssertEqual(margin(60_000).senderLeadInMs, 60_000)
        XCTAssertEqual(margin(9_000_000).senderLeadInMs, 300_000)
        XCTAssertEqual(margin(-10).senderLeadInMs, 0)
    }

    func testARecordFromBeforeTheFieldStillDecodesAndRoundTrips() throws {
        let before = ImportedCommentaryInterjection(
            id: "m", layerId: "l", packageScopedId: "p", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), approvedTranscript: "words")
        // A Margin with no length writes no key, so the stored row is the row an older build wrote and reads.
        let bytes = try JSONEncoder().encode(before)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("senderLeadIn"))
        let decoded = try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: bytes)
        XCTAssertNil(decoded.senderLeadInMs)
        var withLength = decoded
        withLength.senderLeadInMs = 60_000
        let again = try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: JSONEncoder().encode(withLength))
        XCTAssertEqual(again.senderLeadInMs, 60_000)
    }

    func testTheRecordKeyIsWrittenOnlyWhenThereIsALength() throws {
        func record(_ ms: Int?) -> SharedInterjectionPackageRecord {
            SharedInterjectionPackageRecord(
                packageScopedId: "p", createdAt: Date(timeIntervalSince1970: 0),
                anchor: PortableAnchorEvidence(anchorType: .text, exactText: "text"), defaultRepresentationId: "r",
                representations: [SharedInterjectionRepresentation(id: "r", kind: .textOnly, approvedTranscript: "words", provenance: .senderApprovedTextOnly)],
                leadInMs: ms)
        }
        let none = String(decoding: try JSONEncoder().encode(record(nil)), as: UTF8.self)
        XCTAssertFalse(none.contains("leadInMs"), "the packet an older build makes is unchanged")
        let some = try JSONEncoder().encode(record(60_000))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: some) as? [String: Any])?["leadInMs"] as? Int, 60_000)
        // A key of the wrong type refuses the record, as readAloud does.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: some) as? [String: Any])
        for wrong: Any in ["60000", 1.5, true] {
            object["leadInMs"] = wrong
            XCTAssertThrowsError(try JSONDecoder().decode(SharedInterjectionPackageRecord.self, from: JSONSerialization.data(withJSONObject: object)),
                                 "\(wrong)")
        }
    }
}
