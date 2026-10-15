import Foundation
import XCTest
import SessionKit
import ShippedSessionKit

/// Build 29 must still read a followed entry saved with the #1589 `firstSeenAt` stamp. The store writes
/// entries as ISO 8601 JSON in the `records` payload; this decodes that payload with Build 29's frozen model.
final class FeedEntryFirstSeenBuild29Tests: XCTestCase {
    func testEntryWithAFirstSeenStampDecodesWithBuild29sModel() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = SessionKit.FeedEntry(
            id: "entry", subscriptionId: "subscription", canonicalURL: "https://example.com/one",
            title: "Episode One", publishedAt: Date(timeIntervalSince1970: 1_777_000_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_777_100_000)
        )
        let payload = try encoder.encode(entry)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("\"firstSeenAt\""))

        let shipped = try decoder.decode(ShippedSessionKit.FeedEntry.self, from: payload)
        XCTAssertEqual(shipped.id, "entry")
        XCTAssertEqual(shipped.title, "Episode One")
        XCTAssertEqual(shipped.publishedAt, Date(timeIntervalSince1970: 1_777_000_000))
        XCTAssertEqual(shipped.state, .unseen)
    }
}
