import XCTest
@testable import SessionKit

/// #4046 PR 3: what the Lists screen, a list's screen and "Add shows to <list>" show.
final class FollowListScreensTests: XCTestCase {
    private func subscription(_ id: String, title: String? = nil, quiet: Bool = false) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: title ?? id),
            state: quiet ? .muted : .active,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func member(_ id: String, guid: String? = nil) -> ListMember {
        ListMember(feedKey: FeedURLKey.make("https://\(id).example/feed") ?? "", podcastGUID: guid)
    }

    private lazy var subscriptions = [
        subscription("zed", title: "Zed Talks"),
        subscription("amp", title: "amp hour"),
        subscription("moon", title: "Moonshot", quiet: true),
        subscription("blank", title: "  "),
    ]

    func testOverviewRowsAreInChipOrderWithTheirShowCounts() {
        let lists = [
            FollowList(id: "2", name: "Work", members: [member("zed")]),
            FollowList(id: "1", name: "commute", members: [member("amp"), member("moon")]),
            FollowList(id: "3", name: "Empty"),
        ]
        let rows = FollowListScreens.overviewRows(lists: lists, subscriptions: subscriptions)

        XCTAssertEqual(rows.map(\.name), ["commute", "Empty", "Work"])
        XCTAssertEqual(rows.map(\.subtitle), ["2 shows", "0 shows", "1 show"])
        XCTAssertEqual(rows.first?.accessibilityLabel, "commute, 2 shows")
    }

    func testAMemberThatIsNoLongerFollowedIsNotCounted() {
        let lists = [FollowList(id: "1", name: "Old", members: [member("zed"), member("unfollowed")])]
        let rows = FollowListScreens.overviewRows(lists: lists, subscriptions: subscriptions)

        XCTAssertEqual(rows.first?.subtitle, "1 show")
    }

    func testShowsInAListAreAlphabeticalIgnoringCaseAndKeepQuietShows() {
        let list = FollowList(id: "1", name: "L", members: [member("zed"), member("moon"), member("amp")])
        let shows = FollowListScreens.shows(in: list, subscriptions: subscriptions)

        XCTAssertEqual(shows.map(\.id), ["amp", "moon", "zed"], "amp hour, Moonshot, Zed Talks")
    }

    func testAShowIsFoundByItsGUIDWhenItsFeedMoved() {
        let moved = subscription("newhost", title: "Moved Show")
        let list = FollowList(id: "1", name: "L", members: [ListMember(feedKey: "https://old.example/feed", podcastGUID: "GUID-1")])

        XCTAssertEqual(FollowListScreens.shows(in: list, subscriptions: [moved]), [])
        XCTAssertEqual(FollowListScreens.shows(in: list, subscriptions: [moved], podcastGUIDs: ["newhost": "guid-1"]).map(\.id), ["newhost"])
    }

    func testPickerRowsListEveryFollowedShowAlphabeticallyWithTheirTicks() {
        let list = FollowList(id: "1", name: "L", members: [member("moon")])
        let rows = FollowListScreens.pickerRows(for: list, subscriptions: subscriptions)

        XCTAssertEqual(rows.map(\.title), ["amp hour", "blank.example", "Moonshot", "Zed Talks"], "a show with no title is named by its host")
        XCTAssertEqual(rows.map(\.isMember), [false, false, true, false])
    }

    func testNoListsAndNoShowsGiveNothing() {
        XCTAssertEqual(FollowListScreens.overviewRows(lists: [], subscriptions: subscriptions), [])
        XCTAssertEqual(FollowListScreens.pickerRows(for: FollowList(name: "L"), subscriptions: []), [])
        XCTAssertEqual(FollowListScreens.shows(in: FollowList(name: "L"), subscriptions: subscriptions), [])
    }

    func testShowsInTwoOrMoreCountsEachShowOnce() {
        let lists = [
            FollowList(id: "1", name: "A", members: [member("a"), member("b"), member("c")]),
            FollowList(id: "2", name: "B", members: [member("a"), member("b")]),
            FollowList(id: "3", name: "C", members: [member("a")]),
        ]
        XCTAssertEqual(FollowListScreens.showsInTwoOrMore(lists), 2, "a is in three lists and b in two; each counts once")
    }

    func testShowsInTwoOrMoreMatchesAMovedFeedByGUID() {
        let lists = [
            FollowList(id: "1", name: "A", members: [member("old", guid: "G")]),
            FollowList(id: "2", name: "B", members: [member("new", guid: "g")]),
        ]
        XCTAssertEqual(FollowListScreens.showsInTwoOrMore(lists), 1)
    }

    func testShowsInTwoOrMoreIsZeroForNoListsOneListAndDisjointLists() {
        XCTAssertEqual(FollowListScreens.showsInTwoOrMore([]), 0)
        XCTAssertEqual(FollowListScreens.showsInTwoOrMore([FollowList(id: "1", name: "A", members: [member("a"), member("b")])]), 0)
        XCTAssertEqual(FollowListScreens.showsInTwoOrMore([
            FollowList(id: "1", name: "A", members: [member("a")]),
            FollowList(id: "2", name: "B", members: [member("b")]),
        ]), 0)
    }

    func testTheWordsMatchTheDesign() {
        XCTAssertEqual(FollowListWords.showCount(0), "0 shows")
        XCTAssertEqual(FollowListWords.showCount(1), "1 show")
        XCTAssertEqual(FollowListWords.showCount(12), "12 shows")
        XCTAssertEqual(FollowListWords.addShowsTitle(listName: "News"), "Add shows to News")
        XCTAssertEqual(FollowListWords.showsHeader(count: 3), "Shows (3)")
        XCTAssertEqual(FollowListWords.emptyListsTitle, "No lists yet")
    }
}
