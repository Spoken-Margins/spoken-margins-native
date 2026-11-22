import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
import ShippedSessionKit

/// Build 29 must still read a followed feed saved with the #466 "Add every new item" choice.
/// The subscription is saved through the store and the `records` payload it wrote is decoded
/// with Build 29's frozen model (#4309).
final class FeedNewItemPolicyBuild29Tests: XCTestCase {
    func testSubscriptionWithAPolicyDecodesWithBuild29sModel() throws {
        let path = try StoredRecordFile.temporaryPath(for: self)
        let subscription = SessionKit.FeedSubscription(
            id: "subscription-1",
            source: SessionKit.SourceIdentity(id: "source-1", kind: .podcastFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Show"),
            state: .muted,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            newItemPolicy: .addEveryNewItem
        )
        try SQLiteSessionStore(path: path).saveFeedSubscription(subscription)
        let payload = try StoredRecordFile.payload(path: path, kind: "feed_subscription", id: "subscription-1")
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("add_every_new_item"))

        let shipped = try StoredRecordFile.decodeInShippedBuild(ShippedSessionKit.FeedSubscription.self, from: payload)
        XCTAssertEqual(shipped.id, "subscription-1")
        XCTAssertEqual(shipped.source.canonicalURL, "https://example.com/feed")
        XCTAssertEqual(shipped.state, .muted)
        XCTAssertEqual(shipped.createdAt, Date(timeIntervalSince1970: 1_777_000_000))
    }
}
