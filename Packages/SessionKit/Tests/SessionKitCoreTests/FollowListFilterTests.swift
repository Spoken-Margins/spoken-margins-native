import XCTest
@testable import SessionKit

/// #4046: narrowing Following to one list, and the member matching behind it.
final class FollowListFilterTests: XCTestCase {
    func testKeepsOnlyTheListsShowsAndTheirOrder() {
        let fixture = Self.shows(["a", "b", "c", "d"], quiet: ["q"])
        let list = FollowList(id: "l", name: "L", members: [
            ListMember(feedKey: "https://d.example/feed"), ListMember(feedKey: "https://b.example/feed"), ListMember(feedKey: "https://q.example/feed"),
        ])
        let filtered = FollowListFilter.apply(rows: fixture.list.rows, quietRows: fixture.list.quiet, list: list, subscriptions: fixture.subscriptions)
        XCTAssertEqual(filtered.rows.map(\.id), ["b", "d"], "each row stays where Following put it, not in the list's order")
        XCTAssertEqual(filtered.quiet.map(\.id), ["q"], "a Quiet show stays in its list, in the Quiet group")
    }

    func testAnEmptyListAndAnUnknownListShowNothing() {
        let fixture = Self.shows(["a", "b"])
        XCTAssertEqual(
            FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: FollowList(id: "e", name: "E"), subscriptions: fixture.subscriptions),
            FollowingShowList()
        )
        let stranger = FollowList(id: "s", name: "S", members: [ListMember(feedKey: "https://nobody.example/feed")])
        XCTAssertEqual(FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: stranger, subscriptions: fixture.subscriptions).rows, [])
    }

    func testARowWithNoSubscriptionIsLeftOut() {
        let fixture = Self.shows(["a"])
        let list = FollowList(id: "l", name: "L", members: [ListMember(feedKey: "https://a.example/feed")])
        XCTAssertEqual(FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: []).rows, [])
    }

    func testFeedLinkSpellingsThatNameTheSameFeedMatch() {
        // Member keys come from FeedURLKey.make, so a list written from an http link with a trailing slash finds the https feed.
        let fixture = Self.shows(["a"])
        let key = FeedURLKey.make("http://A.example/feed/")
        XCTAssertEqual(key, "https://a.example/feed")
        let list = FollowList(id: "l", name: "L", members: [ListMember(feedKey: key ?? "")])
        XCTAssertEqual(FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: fixture.subscriptions).rows.map(\.id), ["a"])
    }

    func testAShowMatchesByGUIDWhenBothSidesHaveOneAndTheFeedMoved() {
        let fixture = Self.shows(["a"])
        let list = FollowList(id: "l", name: "L", members: [ListMember(feedKey: "https://old-host.example/feed", podcastGUID: "GUID-1")])
        XCTAssertEqual(FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: fixture.subscriptions).rows, [], "no GUID known for the subscription")
        let withGUID = FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: fixture.subscriptions, podcastGUIDs: ["a": " guid-1 "])
        XCTAssertEqual(withGUID.rows.map(\.id), ["a"])
        let other = FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: fixture.subscriptions, podcastGUIDs: ["a": "guid-2"])
        XCTAssertEqual(other.rows, [])
    }

    func testListsContainingAShowComeInChipOrder() {
        let fixture = Self.shows(["a"])
        let key = "https://a.example/feed"
        let lists = [
            FollowList(id: "2", name: "zeta", members: [ListMember(feedKey: key)]),
            FollowList(id: "1", name: "Alpha", members: [ListMember(feedKey: key)]),
            FollowList(id: "3", name: "Other", members: [ListMember(feedKey: "https://b.example/feed")]),
        ]
        XCTAssertEqual(FollowListFilter.lists(containing: fixture.subscriptions[0], in: lists).map(\.name), ["Alpha", "zeta"])
    }

    func testMemberEditing() {
        var list = FollowList(id: "l", name: "L")
        XCTAssertTrue(list.add(ListMember(feedKey: "https://a.example/feed")))
        XCTAssertFalse(list.add(ListMember(feedKey: "https://a.example/feed")), "adding twice changes nothing")
        XCTAssertTrue(list.add(ListMember(feedKey: "https://a.example/feed", podcastGUID: "g")), "an existing member picks up a GUID")
        XCTAssertEqual(list.members, [ListMember(feedKey: "https://a.example/feed", podcastGUID: "g")])
        XCTAssertFalse(list.add(ListMember(feedKey: "https://moved.example/feed", podcastGUID: "G")), "the same GUID on a new host is the same show")
        XCTAssertEqual(list.members.count, 1)
        XCTAssertFalse(list.remove(feedKey: "https://z.example/feed"))
        XCTAssertTrue(list.remove(feedKey: nil, podcastGUID: "g"))
        XCTAssertEqual(list.members, [])
        XCTAssertEqual(ListMember(feedKey: "k", podcastGUID: "  ").podcastGUID, nil, "a blank GUID is none")
    }

    func testAListWith500ShowsFiltersFast() {
        let ids = (0..<500).map { "s\($0)" }
        let fixture = Self.shows(ids)
        let list = FollowList(id: "l", name: "Big", members: ids.map { ListMember(feedKey: "https://\($0).example/feed") })
        XCTAssertEqual(list.members.count, 500)
        measure { _ = FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: fixture.subscriptions) }
        XCTAssertEqual(FollowListFilter.apply(rows: fixture.list.rows, quietRows: [], list: list, subscriptions: fixture.subscriptions).rows.count, 500)
    }

    // MARK: Fixtures

    /// Subscription `x` follows `https://x.example/feed`. Quiet ones are muted.
    private static func shows(_ ids: [String], quiet: [String] = []) -> (subscriptions: [FeedSubscription], list: FollowingShowList) {
        let subscriptions = (ids + quiet).enumerated().map { index, id in
            FeedSubscription(
                id: id,
                source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: id.uppercased()),
                state: quiet.contains(id) ? .muted : .active,
                createdAt: Date(timeIntervalSince1970: Double(1_000 - index))
            )
        }
        return (subscriptions, FollowingShowRows.build(subscriptions: subscriptions, entries: []))
    }
}
