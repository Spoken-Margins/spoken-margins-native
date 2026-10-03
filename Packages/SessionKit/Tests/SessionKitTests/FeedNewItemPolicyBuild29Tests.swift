import Foundation
import XCTest
import SessionKit
import ShippedSessionKit

/// Build 29 must still read a followed feed saved with the #466 "Add every new item" choice.
/// The store writes subscriptions as ISO 8601 JSON in the `records` payload; this decodes that
/// payload with Build 29's frozen model.
final class FeedNewItemPolicyBuild29Tests: XCTestCase {
    func testSubscriptionWithAPolicyDecodesWithBuild29sModel() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let subscription = SessionKit.FeedSubscription(
            id: "subscription-1",
            source: SessionKit.SourceIdentity(id: "source-1", kind: .podcastFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Show"),
            state: .muted,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            newItemPolicy: .addEveryNewItem
        )
        let payload = try encoder.encode(subscription)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("add_every_new_item"))

        let shipped = try decoder.decode(ShippedSessionKit.FeedSubscription.self, from: payload)
        XCTAssertEqual(shipped.id, "subscription-1")
        XCTAssertEqual(shipped.source.canonicalURL, "https://example.com/feed")
        XCTAssertEqual(shipped.state, .muted)
        XCTAssertEqual(shipped.createdAt, Date(timeIntervalSince1970: 1_777_000_000))
    }
}
