import XCTest
@testable import SessionKit

/// #3343: friends and shows sort into one Following list, newest first.
final class FollowingFeedTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000 + 60 * 86_400)
    private func day(_ n: Int) -> Date { base.addingTimeInterval(Double(n) * 86_400) }

    private func show(_ id: String, createdDay: Int = 0) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://example.com/\(id).xml", host: "example.com", title: "Show \(id)"),
            state: .active, createdAt: day(createdDay)
        )
    }

    private func episode(_ id: String, in show: String, day published: Int) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: show, canonicalURL: "https://example.com/\(id)", audioURL: "https://example.com/\(id).mp3",
            title: "Episode \(id)", publishedAt: day(published), state: .unseen, firstSeenAt: day(published)
        )
    }

    /// A Margin from `sender`, recorded on `recorded` and received on `received`; nil days mean no usable date.
    private func margin(_ id: String, from sender: String, recorded: Int?, received: Int?, heard: Bool = false) -> MarginCollection.SharedEntry {
        let layerId = "layer-\(sender)"
        let layer = ImportedCommentaryLayer(
            id: layerId, itemId: "item-\(sender)", packageDigest: "d-\(layerId)", packageId: "p-\(layerId)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Title"),
            displayLabel: sender, importedAt: received.map(day) ?? Date(timeIntervalSince1970: 0)
        )
        var interjection = ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: recorded.map(day) ?? Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), approvedTranscript: "words"
        )
        if heard { interjection.firstHeardAt = day(0) }
        return MarginCollection.SharedEntry(interjection: interjection, layer: layer, itemTitle: "Title")
    }

    private func order(friends: [MarginCollection.SharedEntry], shows: [FeedSubscription], entries: [FeedEntry]) -> [String] {
        let list = FollowingShowRows.build(subscriptions: shows, entries: entries, now: now)
        return FollowingFeed.rows(friends: FollowingFriends.friends(from: friends), shows: list.rows).map(\.id)
    }

    func testFriendsAndShowsInterleaveByDate() {
        let ids = order(
            friends: [margin("a", from: "Ada", recorded: 10, received: 10), margin("b", from: "Blair", recorded: 30, received: 30)],
            shows: [show("old"), show("new")],
            entries: [episode("e1", in: "old", day: 5), episode("e2", in: "new", day: 20)]
        )
        XCTAssertEqual(ids, ["friend::blair", "show::new", "friend::ada", "show::old"],
                       "friends no longer sit above every show")
    }

    func testShowNewerThanEveryFriendComesFirst() {
        let ids = order(
            friends: [margin("a", from: "Ada", recorded: 10, received: 10)],
            shows: [show("s")], entries: [episode("e", in: "s", day: 40)]
        )
        XCTAssertEqual(ids, ["show::s", "friend::ada"])
    }

    func testTieGoesToTheFriendAndEachListKeepsItsOwnOrder() {
        let ids = order(
            friends: [margin("a", from: "Ada", recorded: 10, received: 10), margin("b", from: "Blair", recorded: 10, received: 10)],
            shows: [show("s1"), show("s2")],
            entries: [episode("e1", in: "s1", day: 10), episode("e2", in: "s2", day: 10)]
        )
        XCTAssertEqual(ids, ["friend::ada", "friend::blair", "show::s1", "show::s2"])
    }

    func testPacketRecordedLongAgoButReceivedTodaySortsAsToday() {
        let ids = order(
            friends: [margin("a", from: "Ada", recorded: 1, received: 50)],
            shows: [show("s")], entries: [episode("e", in: "s", day: 30)]
        )
        XCTAssertEqual(ids, ["friend::ada", "show::s"], "the received date counts when it is later")
        XCTAssertEqual(FollowingFriends.friends(from: [margin("a", from: "Ada", recorded: 60, received: 50)]).first?.newestAt, day(60),
                       "the recorded date counts when it is later")
    }

    func testShowWithNoEpisodesAndFriendWithNoDatedMarginSortLast() {
        let ids = order(
            friends: [margin("u", from: "Undated", recorded: nil, received: nil), margin("a", from: "Ada", recorded: 10, received: 10)],
            shows: [show("empty"), show("s")], entries: [episode("e", in: "s", day: 5)]
        )
        XCTAssertEqual(ids, ["friend::ada", "show::s", "friend::undated", "show::empty"])
        XCTAssertNil(FollowingFriends.friends(from: [margin("u", from: "Undated", recorded: nil, received: nil)]).first?.newestAt)
    }

    func testEmptyInputs() {
        XCTAssertEqual(FollowingFeed.rows(friends: [], shows: []), [])
        XCTAssertEqual(order(friends: [margin("a", from: "Ada", recorded: 1, received: 1)], shows: [], entries: []), ["friend::ada"])
        XCTAssertEqual(order(friends: [], shows: [show("s")], entries: []), ["show::s"])
    }

    func testNewCountsPerFriendAndItem() {
        let friends = FollowingFriends.friends(from: [
            margin("a", from: "Ada", recorded: 1, received: 1, heard: true),
            margin("b", from: "Ada", recorded: 2, received: 2),
            margin("c", from: "Ada", recorded: 3, received: 3),
        ])
        XCTAssertEqual(friends.first?.newCount, 2)
        XCTAssertEqual(friends.first?.items.first?.newLabel, "2 new")
        XCTAssertNil(FollowingFriends.friends(from: [margin("a", from: "Ada", recorded: 1, received: 1, heard: true)]).first?.items.first?.newLabel)
    }

    func testItemDetailReadsLikeALibraryRow() {
        let row = LibraryItemRow(
            id: "i", title: "Title", status: "", canDelete: true, continuationProgressPercent: 40,
            mediaType: "podcast", sourceTitle: "The Show"
        )
        XCTAssertEqual(FollowingFriends.itemDetail(row, playbackSpeed: 1).fullLine, "The Show · Podcast · 40%")
        let done = LibraryItemRow(id: "j", title: "T", status: "", canDelete: true, isCompleted: true, mediaType: "article", sourceTitle: "arxiv.org")
        XCTAssertEqual(FollowingFriends.itemDetail(done, playbackSpeed: 1).fullLine, "arxiv.org · Article · Completed")
    }
}
