import XCTest
@testable import SessionKit

/// The "N new" tag on a Following row's picture (#4723): its words and its cap. The row's spoken label keeps the exact count.
final class FollowingNewBadgeTests: XCTestCase {
    func testTheTagReadsNNewAndCapsAboveNinetyNine() {
        let cases: [(Int, String?)] = [
            (0, nil), (-1, nil), (1, "1 new"), (2, "2 new"), (99, "99 new"), (100, "99+ new"), (12_345, "99+ new"),
        ]
        for (count, expected) in cases {
            XCTAssertEqual(FollowingNewBadge.text(count: count), expected, "count \(count)")
        }
    }

    func testAShowRowWithOneHundredFiftyNewShowsTheCappedTagButSpeaksTheExactCount() {
        let followed = Date(timeIntervalSince1970: 1_700_000_000)
        let subscription = FeedSubscription(
            id: "noisy",
            source: SourceIdentity(id: "source-noisy", kind: .podcastFeed, canonicalURL: "https://example.com/noisy.xml", host: "example.com", title: "Noisy Show"),
            state: .active,
            createdAt: followed
        )
        let entries = (1...150).map { n in
            FeedEntry(
                id: "e\(n)", subscriptionId: "noisy", canonicalURL: "https://example.com/e\(n)", audioURL: "https://example.com/e\(n).mp3",
                title: "Episode \(n)", publishedAt: followed.addingTimeInterval(Double(n) * 3_600), state: .unseen,
                firstSeenAt: followed.addingTimeInterval(Double(n) * 3_600)
            )
        }
        let list = FollowingShowRows.build(
            subscriptions: [subscription], entries: entries, lookedAt: [:], libraryEpisodes: [:],
            now: followed.addingTimeInterval(30 * 86_400), calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"))
        let row = try! XCTUnwrap(list.rows.first)
        XCTAssertEqual(row.newCount, 150)
        XCTAssertEqual(row.newBadgeText, "99+ new")
        XCTAssertEqual(row.newLabel, "150 new")
        XCTAssertTrue(row.accessibilityLabel.contains("150 new"), row.accessibilityLabel)
    }

    func testTheStatusSlotHoldsExactlyOneStateOrNothing() {
        typealias S = FollowingRowStatus
        XCTAssertEqual(S.resolve(isAdding: true, isPlayStarting: false, isNewestInLibrary: false), .adding)
        XCTAssertEqual(S.resolve(isAdding: true, isPlayStarting: false, isNewestInLibrary: true), .adding)
        XCTAssertEqual(S.resolve(isAdding: true, isPlayStarting: true, isNewestInLibrary: false), nil)
        XCTAssertEqual(S.resolve(isAdding: true, isPlayStarting: true, isNewestInLibrary: true), .inLibrary)
        XCTAssertEqual(S.resolve(isAdding: false, isPlayStarting: false, isNewestInLibrary: true), .inLibrary)
        XCTAssertNil(S.resolve(isAdding: false, isPlayStarting: false, isNewestInLibrary: false))
    }

    func testAFriendRowUsesTheSameTagAndKeepsTheExactLabel() {
        func friend(_ newCount: Int) -> FollowingFriends.Friend {
            FollowingFriends.Friend(id: "ada", name: "Ada", marginCount: 200, newCount: newCount, newestAt: nil, items: [], summary: "200 Margins on 1 episode")
        }
        XCTAssertNil(friend(0).newBadgeText)
        XCTAssertEqual(friend(3).newBadgeText, "3 new")
        XCTAssertEqual(friend(150).newBadgeText, "99+ new")
        XCTAssertEqual(friend(150).newLabel, "150 new")
    }
}
