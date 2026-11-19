import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #4046 PR 6: list links are their own record kind over a real temporary SQLite file, and a check that finishes while the
/// listener edits the link never writes over the edit.
final class ListLinkStoreTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "list-links-\(UUID().uuidString).sqlite").path
    }

    private func member(_ n: Int, guid: String? = nil) -> ListMember { ListLinkFixture.member(n, guid: guid) }

    private func proposed(_ n: Int) -> ProposedShow {
        ProposedShow(member: member(n), feedURL: ListLinkFixture.feedURL(n), title: "Show \(n)", viaTitle: n == 3 ? "Tech picks" : nil)
    }

    private func fullLink(id: String = "link", listId: String = "list") -> ListLink {
        ListLink(
            id: id, listId: listId, url: "https://friend.example/list.opml", title: "Friend’s list", role: .include,
            etag: "\"v1\"", lastModified: "Wed, 18 Nov 2026 10:00:00 GMT", lastCheckedAt: date(10), status: .gone, statusAt: date(20),
            acceptedMembers: [member(1, guid: "g1"), member(2)], rejectedMembers: [member(9)],
            pending: ListProposal(added: [proposed(3), proposed(4)], removed: [member(2)], checkedAt: date(20)))
    }

    // MARK: relaunch

    func testLinksWithTheirAcceptedRejectedAndWaitingShowsSurviveARelaunch() throws {
        let path = temporaryDatabasePath()
        let first = fullLink(id: "a")
        var second = ListLink(id: "b", listId: "other", url: "https://two.example/l.opml", title: "Two")
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveListLink(first)
            try store.saveListLink(second)
        }
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try store.loadListLinks(), [first, second], "every field, including the proposal and its via title")
        XCTAssertEqual(try store.loadListLink(id: "a"), first)
        XCTAssertNil(try store.loadListLink(id: "missing"))
        second.status = .unreachable
        try store.saveListLink(second)
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadListLink(id: "b")?.status, .unreachable)
        try store.deleteListLink(id: "a")
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadListLinks().map(\.id), ["b"])
    }

    func testDeletingAListDeletesItsLinksAndOnlyTheirs() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveFollowList(FollowList(id: "list", name: "Mine", createdAt: date(1)))
        try store.saveFollowList(FollowList(id: "other", name: "Other", createdAt: date(2)))
        try store.saveListLink(fullLink(id: "a", listId: "list"))
        try store.saveListLink(fullLink(id: "b", listId: "list"))
        try store.saveListLink(fullLink(id: "c", listId: "other"))
        try store.deleteFollowList(id: "list")
        XCTAssertEqual(try store.loadFollowLists().map(\.id), ["other"])
        XCTAssertEqual(try store.loadListLinks().map(\.id), ["c"], "a deleted list is never checked again")
    }

    func testTheStoreActorServesTheRunnersQuestions() async throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveFollowList(FollowList(id: "list", name: "Mine", createdAt: date(1)))
        try store.saveListLink(fullLink())
        let service = ListLinksStore(store: store)
        let links = try await service.listLinks()
        XCTAssertEqual(links.map(\.id), ["link"])
        let ids = try await service.existingListIDs()
        XCTAssertEqual(ids, ["list"])
    }

    // MARK: a check that ends after the listener's own edit

    func testACheckKeepsWhatTheListenerChangedWhileTheNetworkAnswered() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let stored = ListLink(id: "link", listId: "list", url: "https://friend.example/l.opml", title: "Friend", acceptedMembers: [member(1)])
        try store.saveListLink(stored)
        // The check began from `stored`. It found show 2 and show 3 added, and show 1 removed.
        var checked = stored
        checked.status = .ok
        checked.statusAt = date(50)
        checked.lastCheckedAt = date(50)
        checked.etag = "\"v2\""
        checked.url = "https://moved.example/l.opml"
        checked.pending = ListProposal(added: [proposed(2), proposed(3)], removed: [member(1)], checkedAt: date(50))
        // Meanwhile the listener renamed the link's list entry, turned down show 3 and took show 1 out by hand.
        var edited = stored
        edited.title = "Renamed"
        edited.rejectedMembers = [member(3), member(1)]
        try store.saveListLink(edited)

        let saved = try XCTUnwrap(store.saveCheckedListLink(checked))
        XCTAssertEqual(saved.title, "Renamed", "the listener's edit stays")
        XCTAssertEqual(saved.rejectedMembers, [member(3), member(1)])
        XCTAssertEqual(saved.acceptedMembers, [member(1)])
        XCTAssertEqual(saved.url, "https://moved.example/l.opml", "the check's own fields land")
        XCTAssertEqual(saved.etag, "\"v2\"")
        XCTAssertEqual(saved.status, .ok)
        XCTAssertEqual(saved.pending?.added.map(\.title), ["Show 2"], "a show turned down meanwhile is not offered")
        XCTAssertEqual(saved.pending?.removed, [], "a show taken out by hand is not a removal to offer")
        XCTAssertEqual(try store.loadListLink(id: "link"), saved)
    }

    func testAShowTheListenerAcceptedWhileTheCheckRanIsNotOfferedAgain() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        // The check began with show 3 and 4 waiting and ended with a 304 that carries that same proposal. The listener applied
        // the review sheet meanwhile: both shows are accepted and nothing waits.
        var before = fullLink()
        before.pending?.removed = []
        var applied = before
        applied.acceptedMembers += [member(3), member(4)]
        applied.pending = nil
        try store.saveListLink(applied)
        let saved = try XCTUnwrap(store.saveCheckedListLink(before))
        XCTAssertNil(saved.pending, "shows already accepted are not a change to offer")
        XCTAssertEqual(saved.acceptedMembers, applied.acceptedMembers)
    }

    func testACheckThatLeavesNothingToOfferClearsTheWaitingChange() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        var stored = fullLink()
        stored.rejectedMembers = [member(3), member(4)]
        stored.acceptedMembers = []
        try store.saveListLink(stored)
        var checked = stored
        checked.pending = ListProposal(added: [proposed(3), proposed(4)], removed: [], checkedAt: date(60))
        let saved = try XCTUnwrap(store.saveCheckedListLink(checked))
        XCTAssertNil(saved.pending)
    }

    func testACheckOfALinkDeletedMeanwhileSavesNothing() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        XCTAssertNil(try store.saveCheckedListLink(fullLink()))
        XCTAssertEqual(try store.loadListLinks(), [])
    }

    func testMergingAnotherLinksResultChangesNothing() {
        let stored = fullLink(id: "a")
        var other = fullLink(id: "b")
        other.status = .ok
        XCTAssertEqual(stored.merging(checked: other), stored)
    }

    // MARK: Build 29

    func testALinkAddsNoTableColumnOrIndexAndAnOlderBuildSetAsideIsRestoredOnOpen() throws {
        let path = temporaryDatabasePath()
        let link = fullLink()
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        let before = try store.listItems()
        try store.saveListLink(link)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(try store.listItems(), before)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, 'older build could not decode this row', '2026-02-03 04:05:06' FROM records WHERE kind = 'follow_list_link';
            """, at: path)
        try StoreRawSQL.execute("DELETE FROM records WHERE kind = 'follow_list_link';", at: path)
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadListLinks(), [link])
        XCTAssertEqual(try SQLiteSessionStore(path: path).quarantinedRecordCount(), 0)
    }
}
