import Foundation
import SessionKit
import ShippedSessionKit
import XCTest

/// The database the last shipped build opens (#4178): an item marked added again still decodes there, and the old
/// reader ignores the new field. Encoded the way `SQLiteSessionStore` stores a row.
final class AddedAgainShippedReaderTests: XCTestCase {
    func testTheShippedBuildStillReadsAnItemAddedAgain() throws {
        var item = SessionKit.Item(id: "item-browser-essay", title: "Essay", mediaType: "text", text: "Words.",
                                   externalReference: "https://example.com/essay", status: "ready",
                                   externalReferenceType: "url", createdAt: Date(timeIntervalSince1970: 1_777_000_000))
        item.addedAgainAt = Date(timeIntervalSince1970: 1_778_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let stored = try encoder.encode(item)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("addedAgainAt"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shipped = try decoder.decode(ShippedSessionKit.Item.self, from: stored)
        XCTAssertEqual(shipped.id, item.id)
        XCTAssertEqual(shipped.text, "Words.")
        XCTAssertEqual(shipped.createdAt, item.createdAt)
    }
}
