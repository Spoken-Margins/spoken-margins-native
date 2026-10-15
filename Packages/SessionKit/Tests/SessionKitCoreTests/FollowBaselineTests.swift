import Foundation
import XCTest
@testable import SessionKit

/// #1589: following a feed with a long back catalogue must not fill New with its old episodes.
/// An entry is New only if the feed published it after the listener followed it.
final class FollowBaselineTests: XCTestCase {
    private let day: TimeInterval = 86_400
    /// The moment the big feed was followed.
    private let followed = Date(timeIntervalSince1970: 1_800_000_000)

    private func subscription(_ id: String, createdAt: Date) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://example.com/\(id).xml", host: "example.com", title: "Show \(id)"),
            createdAt: createdAt
        )
    }

    private func entry(_ id: String, in subscriptionId: String, published: Date?, firstSeen: Date? = nil) -> FeedEntry {
        FeedEntry(
            id: id,
            subscriptionId: subscriptionId,
            canonicalURL: "https://example.com/\(subscriptionId)/\(id)",
            title: "Episode \(id)",
            publishedAt: published,
            firstSeenAt: firstSeen
        )
    }

    // MARK: The reported flood

    /// One show with a large archive, followed today, next to an older follow with truly new entries.
    /// On `next` before this change all of it listed: the archive's 200 episodes buried the rest.
    func testALargeArchiveFollowedTodayLeavesNewToTheTrulyNewEntries() {
        let archive = subscription("archive", createdAt: followed)
        let other = subscription("other", createdAt: followed.addingTimeInterval(-30 * day))
        let oldEpisodes = (0..<200).map {
            entry("old-\($0)", in: "archive", published: followed.addingTimeInterval(-Double($0 + 1) * 7 * day), firstSeen: followed)
        }
        let archiveFresh = entry("archive-fresh", in: "archive", published: followed.addingTimeInterval(2 * day), firstSeen: followed.addingTimeInterval(2 * day))
        let otherFresh = entry("other-fresh", in: "other", published: followed.addingTimeInterval(-day), firstSeen: followed.addingTimeInterval(-day))

        let candidates = QuickAddFeed.candidates(
            folderFiles: [],
            followedEntries: oldEpisodes + [otherFresh, archiveFresh],
            subscriptions: [archive, other]
        )

        XCTAssertEqual(candidates.map(\.id), ["followed-source:archive-fresh", "followed-source:other-fresh"])
    }

    func testTheArchiveStaysStoredAndOnlyLeavesTheNewList() {
        let archive = subscription("archive", createdAt: followed)
        let old = entry("old", in: "archive", published: followed.addingTimeInterval(-day), firstSeen: followed)
        XCTAssertTrue(FollowBaseline.isBackCatalogue(old, of: archive))
        // The list is the only thing filtered: the entry itself is untouched, so the show's own page can list it.
        XCTAssertEqual(old.state, .unseen)
        XCTAssertEqual(FollowBaseline.newEntries([old], subscriptions: [archive]), [])
    }

    // MARK: Rule table

    func testBaselineRuleTable() {
        let show = subscription("show", createdAt: followed)
        let table: [(name: String, published: Date?, firstSeen: Date?, backCatalogue: Bool)] = [
            ("published long before the follow", followed.addingTimeInterval(-400 * day), followed, true),
            ("published a second before the follow", followed.addingTimeInterval(-1), followed, true),
            ("published at the follow moment", followed, followed.addingTimeInterval(60), false),
            ("published after the follow", followed.addingTimeInterval(1), followed.addingTimeInterval(60), false),
            // The feed's first fetch stamps its entries with the follow moment, whatever date they claim.
            ("claims a date after the follow, was in the first fetch", followed.addingTimeInterval(3_600), followed, true),
            ("claims a date after the follow, in the first fetch, earlier stamp", followed.addingTimeInterval(3_600), followed.addingTimeInterval(-1), true),
            // An old episode the feed lists late is still old.
            ("old episode first seen on a later refresh", followed.addingTimeInterval(-10 * day), followed.addingTimeInterval(day), true),
            // No publish date: the first-seen stamp decides.
            ("undated, in the first fetch", nil, followed, true),
            ("undated, first seen on a later refresh", nil, followed.addingTimeInterval(1), false),
            // Entries saved before the stamp existed fall back to their date, or count as new.
            ("saved before the stamp, dated before the follow", followed.addingTimeInterval(-day), nil, true),
            ("saved before the stamp, dated after the follow", followed.addingTimeInterval(day), nil, false),
            ("saved before the stamp, undated", nil, nil, false)
        ]
        for row in table {
            XCTAssertEqual(
                FollowBaseline.isBackCatalogue(entry("e", in: "show", published: row.published, firstSeen: row.firstSeen), of: show),
                row.backCatalogue,
                row.name
            )
        }
    }

    func testAnEntryOfAnUnlistedSubscriptionIsKept() {
        let kept = entry("orphan", in: "gone", published: followed.addingTimeInterval(-day))
        XCTAssertEqual(FollowBaseline.newEntries([kept], subscriptions: [subscription("show", createdAt: followed)]), [kept])
        XCTAssertEqual(FollowBaseline.newEntries([kept], subscriptions: []), [kept])
    }

    // MARK: Refresh, relaunch, unfollow and follow again

    func testAStoredEntryKeepsItsStampOnEveryRefresh() {
        let stamped = entry("a", in: "show", published: nil, firstSeen: followed)
        XCTAssertEqual(FollowBaseline.firstSeenAt(existing: stamped, followMoment: nil, now: followed.addingTimeInterval(day)), followed)
        // A legacy entry has none, and a refresh does not invent one that would read as new.
        let legacy = entry("b", in: "show", published: nil)
        XCTAssertNil(FollowBaseline.firstSeenAt(existing: legacy, followMoment: nil, now: followed.addingTimeInterval(day)))
    }

    func testANewEntryIsStampedWithTheFollowMomentOnlyOnTheFollowingFetch() {
        let later = followed.addingTimeInterval(day)
        XCTAssertEqual(FollowBaseline.firstSeenAt(existing: nil, followMoment: followed, now: followed.addingTimeInterval(2)), followed)
        XCTAssertEqual(FollowBaseline.firstSeenAt(existing: nil, followMoment: nil, now: later), later)
    }

    /// Unfollow deletes the show's entries and follow again makes a new subscription, so the new
    /// follow moment is the baseline: the catalogue, and anything published before it, stays out.
    func testFollowingAgainMovesTheBaselineForward() {
        let first = subscription("show", createdAt: followed)
        let published = followed.addingTimeInterval(2 * day)
        let wasNew = entry("e", in: "show", published: published, firstSeen: published)
        XCTAssertEqual(FollowBaseline.newEntries([wasNew], subscriptions: [first]).count, 1)

        let again = subscription("show", createdAt: followed.addingTimeInterval(5 * day))
        let refetched = entry("e", in: "show", published: published, firstSeen: again.createdAt)
        XCTAssertEqual(FollowBaseline.newEntries([refetched], subscriptions: [again]), [])
    }

    // MARK: Stored shape

    func testFirstSeenAtRoundTripsAndIsOmittedWhenUnset() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let stamped = entry("a", in: "show", published: nil, firstSeen: followed)
        XCTAssertEqual(try decoder.decode(FeedEntry.self, from: encoder.encode(stamped)).firstSeenAt, followed)
        let legacy = entry("b", in: "show", published: nil)
        XCTAssertFalse(String(decoding: try encoder.encode(legacy), as: UTF8.self).contains("firstSeenAt"))
    }

    // MARK: Clearing a clogged list

    func testClearedMessagesNameTheCount() {
        XCTAssertEqual(FollowingDismissMessages.cleared(count: 1), "Cleared 1 entry from New.")
        XCTAssertEqual(FollowingDismissMessages.cleared(count: 332), "Cleared 332 entries from New.")
        XCTAssertEqual(FollowingDismissMessages.clearUndoAccessibilityLabel(count: 332), "Undo Clear, 332 entries")
    }
}
