import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
import ShippedSessionKit

/// Build 29 must still read a followed entry saved with the #1589 `firstSeenAt` stamp. The entry is saved through the
/// store and the `records` payload it wrote is decoded with Build 29's frozen model (#4309).
final class FeedEntryFirstSeenBuild29Tests: XCTestCase {
    func testEntryWithAFirstSeenStampDecodesWithBuild29sModel() throws {
        let path = try StoredRecordFile.temporaryPath(for: self)
        let entry = SessionKit.FeedEntry(
            id: "entry", subscriptionId: "subscription", canonicalURL: "https://example.com/one",
            title: "Episode One", publishedAt: Date(timeIntervalSince1970: 1_777_000_000),
            firstSeenAt: Date(timeIntervalSince1970: 1_777_100_000)
        )
        try SQLiteSessionStore(path: path).saveFeedEntry(entry)
        let payload = try StoredRecordFile.payload(path: path, kind: "feed_entry", id: "entry")
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("\"firstSeenAt\""))

        let shipped = try StoredRecordFile.decodeInShippedBuild(ShippedSessionKit.FeedEntry.self, from: payload)
        XCTAssertEqual(shipped.id, "entry")
        XCTAssertEqual(shipped.title, "Episode One")
        XCTAssertEqual(shipped.publishedAt, Date(timeIntervalSince1970: 1_777_000_000))
        XCTAssertEqual(shipped.state, .unseen)
    }
}
