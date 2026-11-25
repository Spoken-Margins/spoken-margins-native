import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitPersistence

/// #4046 PR 7a, 7b and 8: adding a list by its web address, the preview's outcome, applying a reviewed change, turning a
/// show down, the change card, and the store calls behind them over a real temporary SQLite file.
final class ListLinkAddAndApplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        ListLinkStubProtocol.reset()
    }

    private func member(_ n: Int) -> ListMember { ListLinkFixture.member(n) }

    private func show(_ n: Int) -> ProposedShow {
        ProposedShow(member: member(n), feedURL: ListLinkFixture.feedURL(n), title: "Show \(n)")
    }

    private func subscription(_ n: Int) -> FeedSubscription {
        let url = ListLinkFixture.feedURL(n)
        return FeedSubscription(
            id: "sub\(n)", source: SourceIdentity(id: "s\(n)", kind: .podcastFeed, canonicalURL: url, host: "shows.example", title: "Show \(n)"),
            state: .active, createdAt: now)
    }

    private func temporaryStore() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: FileManager.default.temporaryDirectory.appending(path: "list-add-\(UUID().uuidString).sqlite").path)
    }

    // MARK: Naming

    func testAListAddedByLinkNeverTakesTheNameOfOneYouHave() {
        let mine = [FollowList(id: "a", name: "Commute"), FollowList(id: "b", name: "commute (2)")]
        XCTAssertEqual(ListLinkNaming.name(forTitle: "Weekend", existing: mine), "Weekend")
        XCTAssertEqual(ListLinkNaming.name(forTitle: "COMMUTE", existing: mine), "COMMUTE (3)", "case-blind, and (2) is taken too")
        XCTAssertEqual(ListLinkNaming.name(forTitle: "Café, news", existing: []), "Café news", "a comma would split a category")
        XCTAssertEqual(ListLinkNaming.name(forTitle: "   ", existing: []), "List")
        let long = String(repeating: "x", count: 60)
        let taken = ListLinkNaming.name(forTitle: long, existing: [])
        XCTAssertEqual(taken.count, FollowListName.maxLength)
        let second = ListLinkNaming.name(forTitle: long, existing: [FollowList(id: "l", name: taken)])
        XCTAssertTrue(second.hasSuffix(" (2)"))
        XCTAssertLessThanOrEqual(second.count, FollowListName.maxLength)
    }

    // MARK: Preview

    func testThePreviewTicksNewShowsAndOnlyKeepsWhatEndedUpFollowed() {
        let plan = ListLinkPreviewPlan(
            shows: [show(1), show(2), show(3), show(4)], documentTitle: "Friend picks", url: "https://friend.example/l.opml",
            leftOut: false, subscriptions: [subscription(2)])
        XCTAssertEqual(plan.title, "Friend picks")
        XCTAssertEqual(plan.host, "friend.example")
        XCTAssertEqual(plan.toFollow.map(\.show.title), ["Show 1", "Show 3", "Show 4"])
        XCTAssertEqual(plan.alreadyFollowed.map(\.show.title), ["Show 2"])
        XCTAssertEqual(plan.defaultSelection, ["show:0", "show:2", "show:3"])
        // Show 1 followed, Show 3 unticked, Show 4 ticked but its follow failed.
        let outcome = plan.outcome(ticked: ["show:0", "show:3"], followedFeedKeys: [member(1).feedKey])
        XCTAssertEqual(outcome.members, [member(1), member(2)], "file order, the followed show and the one already followed")
        XCTAssertEqual(outcome.accepted, outcome.members)
        XCTAssertEqual(outcome.rejected, [member(3)], "a failed follow is neither kept nor turned down, so it is offered again")
    }

    func testAddButtonWords() {
        XCTAssertEqual(ListLinkWords.addButton(toFollow: 3), "Add list and follow 3")
        XCTAssertEqual(ListLinkWords.addButton(toFollow: 0), "Add list")
        XCTAssertEqual(ListLinkWords.addButton(toFollow: 2, including: true), "Include list and follow 2")
        XCTAssertEqual(ListLinkWords.addButton(toFollow: 0, including: true), "Include list")
    }

    // MARK: Applying a change

    private func linkWithChange(checkedAt: Date) -> (ListLink, FollowList) {
        let list = FollowList(id: "list", name: "Friend picks", members: [member(1), member(2), member(5)])
        let link = ListLink(
            id: "link", listId: "list", url: "https://friend.example/l.opml", title: "Friend picks",
            acceptedMembers: [member(1), member(2)],
            pending: ListProposal(added: [show(3), show(4)], removed: [member(1), member(2)], checkedAt: checkedAt))
        return (link, list)
    }

    func testApplyFollowsTickedAddsTurnsDownUntickedAndKeepsUntickedRemovalsAsYourOwn() throws {
        let (link, list) = linkWithChange(checkedAt: now)
        let applied = try XCTUnwrap(ListLinkEdits.applying(
            link: link, list: list, reviewed: now, tickedAdded: [member(3).feedKey], tickedRemoved: [member(1).feedKey],
            followedFeedKeys: [member(3).feedKey]))
        XCTAssertEqual(applied.list.members, [member(2), member(5), member(3)], "1 left, 3 joined, 2 kept")
        XCTAssertEqual(applied.link.acceptedMembers, [member(3)], "2 is now the listener's own, so it can't be removed again")
        XCTAssertEqual(applied.link.rejectedMembers, [member(4)])
        XCTAssertNil(applied.link.pending)
    }

    func testApplyWithNothingTickedTurnsDownEveryAddAndRemovesNothing() throws {
        let (link, list) = linkWithChange(checkedAt: now)
        let applied = try XCTUnwrap(ListLinkEdits.applying(
            link: link, list: list, reviewed: now, tickedAdded: [], tickedRemoved: [], followedFeedKeys: []))
        XCTAssertEqual(applied.list.members, list.members)
        XCTAssertEqual(applied.link.rejectedMembers, [member(3), member(4)])
        XCTAssertNil(applied.link.pending)
    }

    func testATickedAddWhoseFollowFailedIsOfferedAgain() throws {
        let (link, list) = linkWithChange(checkedAt: now)
        let applied = try XCTUnwrap(ListLinkEdits.applying(
            link: link, list: list, reviewed: now, tickedAdded: [member(3).feedKey], tickedRemoved: [], followedFeedKeys: []))
        XCTAssertFalse(applied.list.members.contains(member(3)))
        XCTAssertFalse(applied.link.acceptedMembers.contains(member(3)))
        XCTAssertFalse(applied.link.rejectedMembers.contains(member(3)))
    }

    func testAStaleOrSecondApplyChangesNothing() {
        let (link, list) = linkWithChange(checkedAt: now)
        XCTAssertNil(ListLinkEdits.applying(
            link: link, list: list, reviewed: now.addingTimeInterval(-60), tickedAdded: [], tickedRemoved: [], followedFeedKeys: []))
        var applied = link
        applied.pending = nil
        XCTAssertNil(ListLinkEdits.applying(
            link: applied, list: list, reviewed: now, tickedAdded: [], tickedRemoved: [], followedFeedKeys: []))
    }

    // MARK: Turning a show down

    func testRemovingOrUnfollowingAShowTurnsItDownOnlyWhereItWasTaken() {
        let a = ListLink(id: "a", listId: "one", url: "https://x.example/a", title: "A", acceptedMembers: [member(1), member(2)],
                         pending: ListProposal(added: [], removed: [member(1)], checkedAt: now))
        let b = ListLink(id: "b", listId: "two", url: "https://x.example/b", title: "B", acceptedMembers: [member(1)])
        let c = ListLink(id: "c", listId: "one", url: "https://x.example/c", title: "C", acceptedMembers: [member(3)])
        let fromOne = ListLinkEdits.rejecting(member(1), in: [a, b, c], listID: "one")
        XCTAssertEqual(fromOne.map(\.id), ["a"])
        XCTAssertEqual(fromOne[0].acceptedMembers, [member(2)])
        XCTAssertEqual(fromOne[0].rejectedMembers, [member(1)])
        XCTAssertNil(fromOne[0].pending, "a waiting removal of the same show is moot")
        XCTAssertEqual(ListLinkEdits.rejecting(member(1), in: [a, b, c]).map(\.id), ["a", "b"], "unfollow: every link")
    }

    // MARK: Change card

    func testTheChangeCardNamesOneListOrCountsSeveral() {
        let lists = [FollowList(id: "z", name: "Zebra"), FollowList(id: "a", name: "Alpha")]
        let one = ListLink(id: "1", listId: "z", url: "https://x.example/z", title: "Z",
                           pending: ListProposal(added: [show(1)], removed: [], checkedAt: now))
        XCTAssertEqual(ListChangeCard.text(links: [one], lists: lists), ListLinkWords.changeCard(listName: "Zebra", proposal: one.pending!))
        let two = ListLink(id: "2", listId: "a", url: "https://x.example/a", title: "A",
                           pending: ListProposal(added: [], removed: [member(2)], checkedAt: now))
        XCTAssertEqual(ListChangeCard.text(links: [one, two], lists: lists), "2 lists changed")
        XCTAssertEqual(ListChangeCard.waiting(links: [one, two], lists: lists).map(\.id), ["2", "1"], "chip order: Alpha first")
        let orphan = ListLink(id: "3", listId: "gone", url: "https://x.example/g", title: "G",
                              pending: ListProposal(added: [show(1)], removed: [], checkedAt: now))
        XCTAssertNil(ListChangeCard.text(links: [orphan], lists: lists), "a deleted list's link shows no card")
    }

    // MARK: Fetch for the preview

    func testFetchReadsAListAndKeepsWhereAPermanentRedirectEnded() async throws {
        let old = "https://old.example/list.opml", new = "https://new.example/list.opml"
        ListLinkStubProtocol.redirect(old, to: new)
        ListLinkStubProtocol.serve(new, headers: ["ETag": "\"v1\""], text: ListLinkFixture.opml(title: "Picks", rows: ListLinkFixture.rows(1...2)))
        let fetched = try await ListLinkChecker(session: ListLinkStubProtocol.session()).fetch(URL(string: old)!)
        XCTAssertEqual(fetched.url, new)
        XCTAssertEqual(fetched.resolution.title, "Picks")
        XCTAssertEqual(fetched.resolution.shows.map(\.title), ["Show 1", "Show 2"])
        XCTAssertEqual(fetched.etag, "\"v1\"")
    }

    func testFetchFailuresSayWhatWentWrong() async {
        let checker = ListLinkChecker(session: ListLinkStubProtocol.session())
        ListLinkStubProtocol.serve("https://x.example/page", text: "<html><body>Hello</body></html>")
        ListLinkStubProtocol.serve("https://x.example/offline", .failure(.notConnectedToInternet))
        let cases: [(String, ListLinkFetchFailure)] = [
            ("https://x.example/missing", .unreachable),
            ("https://x.example/offline", .unreachable),
            ("https://x.example/page", .notAList),
        ]
        for (url, expected) in cases {
            do {
                _ = try await checker.fetch(URL(string: url)!)
                XCTFail("\(url) should fail")
            } catch let failure as ListLinkFetchFailure {
                XCTAssertEqual(failure, expected, url)
            } catch {
                XCTFail("\(url): \(error)")
            }
        }
    }

    // MARK: Store

    func testAddingAListByLinkSavesTheListAndItsLinkUnderAFreeName() async throws {
        let store = try temporaryStore()
        try store.saveFollowList(FollowList(id: "mine", name: "Picks", createdAt: now, members: [member(9)]))
        let links = ListLinksStore(store: store)
        let url = "https://friend.example/l.opml"
        let added = try await links.addList(title: "Picks", members: [member(1)], link: { listID in
            ListLinkScreens.link(listID: listID, url: url, title: "Picks", role: .own, etag: nil, lastModified: nil,
                                 accepted: [ListLinkFixture.member(1)], rejected: [], now: Date(timeIntervalSince1970: 1))
        }, listID: "new", now: now)
        XCTAssertEqual(added.listID, "new")
        XCTAssertEqual(added.lists.first { $0.id == "new" }?.name, "Picks (2)")
        XCTAssertEqual(added.lists.first { $0.id == "mine" }?.members, [member(9)], "the listener's list is untouched")
        XCTAssertEqual(added.links.map(\.listId), ["new"])
    }

    func testApplyInTheStoreAppliesOnceAndRejectSavesTurnedDownShows() async throws {
        let store = try temporaryStore()
        let (link, list) = linkWithChange(checkedAt: now)
        try store.saveFollowList(list)
        try store.saveListLink(link)
        let links = ListLinksStore(store: store)
        let first = try await links.apply(
            linkID: "link", reviewed: now, tickedAdded: [member(3).feedKey], tickedRemoved: [], followedFeedKeys: [member(3).feedKey])
        XCTAssertEqual(first.lists[0].members.count, 4)
        let second = try await links.apply(
            linkID: "link", reviewed: now, tickedAdded: [member(3).feedKey, member(4).feedKey], tickedRemoved: [],
            followedFeedKeys: [member(3).feedKey, member(4).feedKey])
        XCTAssertEqual(second.lists, first.lists, "a double tap applies once")
        let rejected = try await links.reject(member(3), listID: "list")
        XCTAssertTrue(rejected.links[0].rejectedMembers.contains(member(3)))
        XCTAssertEqual(rejected.changedIDs, ["link"])
        let restored = try await links.restoreAccepted(member(3), linkIDs: rejected.changedIDs, listIDs: ["list"])
        XCTAssertTrue(restored[0].acceptedMembers.contains(member(3)), "Undo after an unfollow takes the show again")
        XCTAssertFalse(restored[0].rejectedMembers.contains(member(3)))
        _ = try await links.reject(member(3), listID: "list")
        let remaining = try await links.delete(linkID: "link")
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(try store.loadFollowList(id: "list")?.members.count, 4, "stopping updates keeps every show")
    }

    func testIncludingAListAddsItsShowsToYourList() async throws {
        let store = try temporaryStore()
        try store.saveFollowList(FollowList(id: "mine", name: "Mine", createdAt: now, members: [member(1)]))
        let include = ListLinkScreens.link(listID: "mine", url: "https://friend.example/l.opml", title: "Friend", role: .include,
                                           etag: nil, lastModified: nil, accepted: [member(2)], rejected: [], now: now)
        let result = try await ListLinksStore(store: store).addInclude(include, members: [member(1), member(2)])
        XCTAssertEqual(result.lists[0].members, [member(1), member(2)])
        XCTAssertEqual(result.links.map(\.role), [.include])
        XCTAssertEqual(ListLinkScreens.viaTitle(for: member(2), listID: "mine", links: result.links), "Friend")
        XCTAssertNil(ListLinkScreens.viaTitle(for: member(1), listID: "mine", links: result.links))
    }

    /// Audit of f7eae8d: an include of an address listing a show already in the list must not offer that show as added on
    /// the next check (and so can never offer to remove it later).
    func testAnIncludeLeavesShowsAlreadyInYourListAsYourOwn() {
        let mine = FollowList(id: "mine", name: "Mine", createdAt: now, members: [member(1)])
        let made = ListLinkScreens.link(listID: "mine", url: "https://friend.example/l.opml", title: "Friend", role: .include,
                                        etag: nil, lastModified: nil, accepted: [member(1), member(2)], rejected: [], now: now)
        let link = ListLinkEdits.keepingListenersOwn(made, in: mine)
        XCTAssertEqual(link.acceptedMembers, [member(2)])
        XCTAssertEqual(link.rejectedMembers, [member(1)])
        XCTAssertNil(ListLinkDiff.proposal(
            resolved: [show(1), show(2)], accepted: link.acceptedMembers, rejected: link.rejectedMembers, checkedAt: now))
        let dropped = ListLinkDiff.proposal(
            resolved: [show(2)], accepted: link.acceptedMembers, rejected: link.rejectedMembers, checkedAt: now)
        XCTAssertNil(dropped, "the address dropping your own show offers no removal")
        XCTAssertEqual(ListLinkEdits.keepingListenersOwn(made, in: nil), made)
    }

    func testUndoAfterAnUnfollowTakesTheShowAgainOnlyWhereTheUnfollowTurnedItDown() {
        func link(_ id: String, list: String) -> ListLink {
            ListLinkScreens.link(id: id, listID: list, url: "https://\(list).example/l.opml", title: list, role: .own,
                                 etag: nil, lastModified: nil, accepted: [], rejected: [member(1)], now: now)
        }
        let turnedDown = link("a-link", list: "a"), otherList = link("b-link", list: "b"), earlier = link("c-link", list: "a")
        let changed = ListLinkEdits.restoringAccepted(
            member(1), in: [turnedDown, otherList, earlier], linkIDs: ["a-link", "b-link"], listIDs: ["a"])
        XCTAssertEqual(changed.map(\.id), ["a-link"], "a list it didn't go back into, or a link that turned it down earlier, stays")
        XCTAssertEqual(changed.first?.acceptedMembers, [member(1)])
        XCTAssertEqual(changed.first?.rejectedMembers, [])
    }
}

final class ListLinkWebURLTests: XCTestCase {
    func testWhichPastedTextIsProbedAsAWebAddress() {
        XCTAssertEqual(ListLinkWords.webURL(" https://friend.example/l.opml\n")?.absoluteString, "https://friend.example/l.opml")
        XCTAssertEqual(ListLinkWords.webURL("friend.example/l.opml")?.absoluteString, "https://friend.example/l.opml")
        XCTAssertEqual(ListLinkWords.webURL("HTTP://Friend.example/x")?.host, "Friend.example")
        XCTAssertNil(ListLinkWords.webURL(""))
        XCTAssertNil(ListLinkWords.webURL("planet money"))
        XCTAssertNil(ListLinkWords.webURL("localhost/feed"))
        XCTAssertNil(ListLinkWords.webURL("podcast://friend.example/feed"))
        XCTAssertNil(ListLinkWords.webURL("ftp://friend.example/l.opml"))
    }
}
