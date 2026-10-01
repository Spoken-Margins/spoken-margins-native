import Foundation
import XCTest
@testable import SessionKit

/// The per-feed "Add every new item" choice (#466): which refreshed entries it adds, and that
/// subscriptions saved before it existed still read as "Let me pick".
final class FeedNewItemPolicyTests: XCTestCase {
    private func entry(_ id: String, state: FeedEntryState = .unseen) -> FeedEntry {
        FeedEntry(id: id, subscriptionId: "sub", canonicalURL: "https://example.com/\(id)", title: id, state: state)
    }

    func testAddEveryNewItemAddsOnlyEntriesFirstSeenInThisRefresh() {
        let existing = [entry("old"), entry("older", state: .seen)]
        let refreshed = [entry("new"), entry("old"), entry("older", state: .seen)]
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: refreshed, existing: existing, policy: .addEveryNewItem).map(\.id), ["new"])
    }

    func testLetMePickAndAMissingPolicyAddNothing() {
        let existing = [entry("old")]
        let refreshed = [entry("new"), entry("old")]
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: refreshed, existing: existing, policy: .letMePick), [])
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: refreshed, existing: existing, policy: nil), [])
    }

    func testTheBackCatalogueAtFollowTimeIsNeverAdded() {
        let backCatalogue = [entry("one"), entry("two"), entry("three")]
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: backCatalogue, existing: [], policy: .addEveryNewItem), [])
    }

    func testImportedAndDismissedEntriesAreNeverAddedAgain() {
        let existing = [entry("imported", state: .imported), entry("dismissed", state: .dismissed)]
        let refreshed = [entry("imported", state: .imported), entry("dismissed", state: .dismissed)]
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: refreshed, existing: existing, policy: .addEveryNewItem), [])
        // An entry that somehow arrives already imported or dismissed is not added either.
        let marked = [entry("fresh-imported", state: .imported), entry("fresh-dismissed", state: .dismissed)]
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: marked, existing: [entry("x")], policy: .addEveryNewItem), [])
    }

    func testARepeatedEntryInOneRefreshIsAddedOnce() {
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: [entry("new"), entry("new")], existing: [entry("old")], policy: .addEveryNewItem).map(\.id), ["new"])
    }

    func testSubscriptionSavedWithoutTheFieldDecodesAsLetMePick() throws {
        let payload = Data("""
        {"id":"subscription-1","source":{"id":"source-1","kind":"podcast_feed","canonicalURL":"https://example.com/feed","host":"example.com","title":"Show"},
         "state":"active","createdAt":"2026-09-01T12:00:00Z"}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let subscription = try decoder.decode(FeedSubscription.self, from: payload)
        XCTAssertNil(subscription.newItemPolicy)
        XCTAssertEqual(FeedNewItemPolicy.entriesToAdd(new: [entry("new")], existing: [entry("old")], policy: subscription.newItemPolicy), [])
    }

    func testPolicyRoundTripsAndIsOmittedWhenUnset() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let source = SourceIdentity(id: "s", kind: .podcastFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Show")
        let set = FeedSubscription(id: "a", source: source, createdAt: Date(timeIntervalSince1970: 0), newItemPolicy: .addEveryNewItem)
        XCTAssertEqual(try decoder.decode(FeedSubscription.self, from: encoder.encode(set)).newItemPolicy, .addEveryNewItem)
        let unset = FeedSubscription(id: "b", source: source, createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(String(decoding: try encoder.encode(unset), as: UTF8.self).contains("newItemPolicy"))
    }
}
