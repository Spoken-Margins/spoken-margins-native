import XCTest
@testable import SessionKit

/// #4046 PR 2: what Following shows under a list chip. With All selected it is exactly what it was.
final class FollowingByListTests: XCTestCase {
    private func subscription(_ id: String, quiet: Bool = false, at index: Int) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: id.uppercased()),
            state: quiet ? .muted : .active,
            createdAt: Date(timeIntervalSince1970: Double(1_000 - index))
        )
    }

    /// Shows a, b, c, d and Quiet q, with a friend row first.
    private struct Fixture {
        var subscriptions: [FeedSubscription]
        var shows: FollowingShowList
        var feedRows: [FollowingFeed.Row]
    }

    private func fixture(_ ids: [String] = ["a", "b", "c", "d"], quiet: [String] = ["q"]) -> Fixture {
        let subscriptions = ids.enumerated().map { subscription($1, at: $0) }
            + quiet.enumerated().map { subscription($1, quiet: true, at: ids.count + $0) }
        let shows = FollowingShowRows.build(subscriptions: subscriptions, entries: [])
        let friend = FollowingFriends.Friend(
            id: "ada", name: "Ada", marginCount: 1, newCount: 0, newestAt: Date(timeIntervalSince1970: 5_000), items: [], summary: "1 Margin on 1 episode"
        )
        return Fixture(subscriptions: subscriptions, shows: shows, feedRows: [.friend(friend)] + shows.rows.map(FollowingFeed.Row.show))
    }

    private func member(_ id: String) -> ListMember { ListMember(feedKey: "https://\(id).example/feed") }

    func testAllLeavesEveryRowAsItWas() {
        let f = fixture()
        let lists = [FollowList(id: "l", name: "L", members: [member("a")])]
        let screen = FollowingByList.screen(selected: nil, lists: lists, feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions)
        XCTAssertEqual(screen.rows, f.feedRows, "friends and shows, in the order Following gave them (J13)")
        XCTAssertEqual(screen.quiet, f.shows.quiet)
        XCTAssertNil(screen.allQuietNote)
        XCTAssertNil(screen.emptyListText)
        XCTAssertFalse(screen.opensQuietGroup)
    }

    func testAListKeepsItsShowsInFollowingsOrderAndHidesFriends() {
        let f = fixture()
        let list = FollowList(id: "l", name: "L", members: [member("d"), member("b"), member("q")])
        let screen = FollowingByList.screen(selected: "l", lists: [list], feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions)
        XCTAssertEqual(screen.rows.map(\.id), ["show::b", "show::d"])
        XCTAssertEqual(screen.quiet.map(\.id), ["q"], "a Quiet show stays in its list, in the Quiet group")
        XCTAssertNil(screen.allQuietNote)
        XCTAssertNil(screen.emptyListText)
    }

    func testAListOfOnlyQuietShowsSaysSoAndOpensTheGroup() {
        let f = fixture()
        let list = FollowList(id: "l", name: "Sleepy", members: [member("q")])
        let screen = FollowingByList.screen(selected: "l", lists: [list], feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions)
        XCTAssertEqual(screen.rows, [])
        XCTAssertEqual(screen.allQuietNote, "Every show in Sleepy is Quiet.")
        XCTAssertTrue(screen.opensQuietGroup)
        XCTAssertNil(screen.emptyListText)
    }

    func testAnEmptyListSaysWhereToAddAShow() {
        let f = fixture()
        let empty = FollowList(id: "e", name: "Later")
        let screen = FollowingByList.screen(selected: "e", lists: [empty], feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions)
        XCTAssertEqual(screen.rows, [])
        XCTAssertEqual(screen.quiet, [])
        XCTAssertEqual(screen.emptyListText, "No shows in Later yet. Add one from a show’s page.")
        XCTAssertNil(screen.allQuietNote)
    }

    func testADeletedOrUnloadedSelectionShowsAll() {
        let f = fixture()
        XCTAssertNil(FollowingByList.resolvedSelection("gone", in: []), "before the lists load, All with no chips")
        XCTAssertNil(FollowingByList.resolvedSelection("gone", in: [FollowList(id: "l", name: "L")]))
        XCTAssertEqual(FollowingByList.resolvedSelection("l", in: [FollowList(id: "l", name: "L")]), "l")
        let screen = FollowingByList.screen(selected: "gone", lists: [], feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions)
        XCTAssertEqual(screen.rows, f.feedRows, "never a half-filtered list")
    }

    func testAShowInTwoListsIsOneRowInEach() {
        let f = fixture()
        let one = FollowList(id: "1", name: "One", members: [member("a"), member("b")])
        let two = FollowList(id: "2", name: "Two", members: [member("b"), member("c")])
        let lists = [one, two]
        func ids(_ id: String) -> [String] {
            FollowingByList.screen(selected: id, lists: lists, feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions).rows.map(\.id)
        }
        XCTAssertEqual(ids("1"), ["show::a", "show::b"])
        XCTAssertEqual(ids("2"), ["show::b", "show::c"])
        XCTAssertEqual(
            FollowingByList.screen(selected: nil, lists: lists, feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions).rows.filter { $0.id == "show::b" }.count, 1
        )
    }

    func testAShowUnfollowedBehindTheListsBackIsNotShown() {
        // The list still names a feed the listener no longer follows (a file import in a later slice): no row, no crash.
        let f = fixture(["a"], quiet: [])
        let list = FollowList(id: "l", name: "L", members: [member("a"), member("gone")])
        let screen = FollowingByList.screen(selected: "l", lists: [list], feedRows: f.feedRows, shows: f.shows, subscriptions: f.subscriptions)
        XCTAssertEqual(screen.rows.map(\.id), ["show::a"])
    }
}
