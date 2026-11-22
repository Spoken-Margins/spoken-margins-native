import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The followed show the UI-test launch seeds for the Up next card's captures (#3863): the card must have something
/// to show in each state the Design asks to capture.
final class FollowedShowSeedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func libraryEpisodes(_ show: (subscription: FeedSubscription, entries: [FeedEntry], libraryItem: Item)) throws -> [String: FollowingLibraryEpisode] {
        let path = FileManager.default.temporaryDirectory.appending(path: "followed-show-seed-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(show.libraryItem)
        return FollowingLibraryEpisodes.resolve(entries: show.entries, items: try store.listItemSummaries(), sessions: [])
    }

    func testTheCardFeaturesTheNewestEpisodeWithALongTitleAndADescription() throws {
        let show = UITestingLaunchSeed.followedShow(now: now)
        let card = try XCTUnwrap(FollowingUpNext.card(entries: show.entries, libraryEpisodes: try libraryEpisodes(show)))
        XCTAssertEqual(card.entry.id, "ui-test-followed-ep3")
        XCTAssertGreaterThan(card.entry.title.count, 100)
        let description = try XCTUnwrap(card.description)
        XCTAssertTrue(description.contains("walkers & birds"), "entities decode")
        XCTAssertFalse(card.isInLibrary)
    }

    func testTheEpisodeWithNoDescriptionIsNextOnceTheFirstIsGone() throws {
        let show = UITestingLaunchSeed.followedShow(now: now)
        let rest = show.entries.filter { $0.id != "ui-test-followed-ep3" }
        let card = try XCTUnwrap(FollowingUpNext.card(entries: rest, libraryEpisodes: try libraryEpisodes(show)))
        XCTAssertEqual(card.entry.id, "ui-test-followed-ep2")
        XCTAssertNil(card.description)
    }

    func testTheOlderEntryIsInTheLibraryAsTheSeededItem() throws {
        let show = UITestingLaunchSeed.followedShow(now: now)
        let resolved = try libraryEpisodes(show)
        XCTAssertEqual(resolved["ui-test-followed-ep1"]?.itemID, UITestingLaunchSeed.followedShowLibraryItemId)
        XCTAssertEqual(show.entries.first { $0.id == "ui-test-followed-ep1" }?.state, .imported)
    }

    func testTheShowIsActiveAndEveryEntryBelongsToIt() {
        let show = UITestingLaunchSeed.followedShow(now: now)
        XCTAssertEqual(show.subscription.state, .active)
        XCTAssertEqual(Set(show.entries.map(\.subscriptionId)), [show.subscription.id])
        XCTAssertTrue(show.entries.allSatisfy { $0.audioDurationMs ?? 0 > 0 && $0.audioURL != nil })
    }

    func testTheFollowedShowRowsNameTheSameEpisodeAsTheCard() throws {
        let show = UITestingLaunchSeed.followedShow(now: now)
        let episodes = try libraryEpisodes(show)
        let list = FollowingShowRows.build(subscriptions: [show.subscription], entries: show.entries, libraryEpisodes: episodes, now: now)
        XCTAssertEqual(list.rows.count, 1)
        XCTAssertTrue(list.rows[0].accessibilityLabel.contains("Up next: Why the river path bends"), list.rows[0].accessibilityLabel)
    }
}
