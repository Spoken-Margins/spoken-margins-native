import Foundation
import XCTest
@testable import SessionKit

/// The values the on-device model client reads and writes (moved from the app target, #318). The model's
/// context string is JSON in these exact key names, so they are pinned here.
final class LocalInterjectionSummaryModelsTests: XCTestCase {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPayloadDecodesFromTheContextJSONTheModelIsGiven() throws {
        let context = """
        {"schemaVersion":"v1","itemTitle":"Essay","interjections":[
          {"id":"m1","anchorBefore":"before words","anchorAfter":"after words","note":"Why this?"}]}
        """
        let payload = try JSONDecoder().decode(LocalInterjectionSummaryPayload.self, from: Data(context.utf8))
        XCTAssertEqual(
            payload,
            LocalInterjectionSummaryPayload(
                schemaVersion: "v1",
                itemTitle: "Essay",
                interjections: [
                    LocalInterjectionSummaryRecord(
                        id: "m1",
                        anchorBefore: "before words",
                        anchorAfter: "after words",
                        note: "Why this?"
                    )
                ]
            )
        )
    }

    func testPayloadIgnoresExtraKeysFromTheFullExport() throws {
        let context = """
        {"schemaVersion":"spoken-margins.export.v1","itemTitle":"Essay","item":{"id":"i"},
         "interjections":[{"id":"m1","anchorBefore":"a","anchorAfter":"b","note":"n","roughPercent":40,"page":3}]}
        """
        let payload = try JSONDecoder().decode(LocalInterjectionSummaryPayload.self, from: Data(context.utf8))
        XCTAssertEqual(payload.interjections.map(\.id), ["m1"])
        XCTAssertEqual(payload.interjections.first?.note, "n")
    }

    func testPayloadRejectsARecordMissingItsNote() {
        let context = #"{"schemaVersion":"v1","itemTitle":"T","interjections":[{"id":"m1","anchorBefore":"a","anchorAfter":"b"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LocalInterjectionSummaryPayload.self, from: Data(context.utf8)))
    }

    func testPayloadKeepsItsKeyNamesAndOrderOfRecords() throws {
        let payload = LocalInterjectionSummaryPayload(
            schemaVersion: "v1",
            itemTitle: "T",
            interjections: (1...3).map {
                LocalInterjectionSummaryRecord(id: "m\($0)", anchorBefore: "b", anchorAfter: "a", note: "n\($0)")
            }
        )
        let json = try object(payload)
        XCTAssertEqual(Set(json.keys), ["schemaVersion", "itemTitle", "interjections"])
        let records = try XCTUnwrap(json["interjections"] as? [[String: Any]])
        XCTAssertEqual(records.compactMap { $0["id"] as? String }, ["m1", "m2", "m3"])
        XCTAssertEqual(Set(try XCTUnwrap(records.first).keys), ["id", "anchorBefore", "anchorAfter", "note"])

        let decoded = try JSONDecoder().decode(
            LocalInterjectionSummaryPayload.self,
            from: try JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded, payload)
    }

    func testLabelDefaultsLeaveEligibilityUnset() throws {
        let label = LocalListeningMapLabel(title: "Chapter 1", description: "A bounded section.")
        XCTAssertNil(label.eligibility)
        XCTAssertNil(label.eligibilityReason)
        let decoded = try JSONDecoder().decode(
            LocalListeningMapLabel.self,
            from: Data(#"{"title":"Chapter 1","description":"A bounded section."}"#.utf8)
        )
        XCTAssertEqual(decoded, label)
    }

    func testLabelRoundTripsEligibilityAndItsReason() throws {
        var label = LocalListeningMapLabel(title: "Ads", description: "A sponsor read.")
        label.eligibility = .excluded
        label.eligibilityReason = "Sponsor message"
        let json = try object(label)
        XCTAssertEqual(json["eligibility"] as? String, "excluded")
        XCTAssertEqual(json["eligibilityReason"] as? String, "Sponsor message")
        let decoded = try JSONDecoder().decode(LocalListeningMapLabel.self, from: try JSONEncoder().encode(label))
        XCTAssertEqual(decoded, label)
        XCTAssertNotEqual(decoded, LocalListeningMapLabel(title: "Ads", description: "A sponsor read."))
    }

    func testLabelRejectsAnEligibilityTheModelMadeUp() {
        let raw = #"{"title":"T","description":"D","eligibility":"maybe"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LocalListeningMapLabel.self, from: Data(raw.utf8)))
    }

    func testMeaningSlotsAllowNoQuestion() throws {
        let withoutQuestion = try JSONDecoder().decode(
            LocalInterjectionMeaningSlots.self,
            from: Data(#"{"points":["First","Second"]}"#.utf8)
        )
        XCTAssertNil(withoutQuestion.question)
        XCTAssertEqual(withoutQuestion.points, ["First", "Second"])

        let withQuestion = try JSONDecoder().decode(
            LocalInterjectionMeaningSlots.self,
            from: Data(#"{"question":"Does it scale?","points":[]}"#.utf8)
        )
        XCTAssertEqual(withQuestion, LocalInterjectionMeaningSlots(question: "Does it scale?", points: []))
    }

    func testMeaningSlotsRejectAReplyWithoutPoints() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(LocalInterjectionMeaningSlots.self, from: Data(#"{"question":"Why?"}"#.utf8))
        )
    }
}
