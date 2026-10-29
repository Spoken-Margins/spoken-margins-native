import XCTest
@testable import SessionKit

final class FirstRunListenChoiceTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func show(_ id: String, kind: SourceIdentityKind = .podcastFeed, state: FeedSubscriptionState = .active) -> FeedSubscription {
        FeedSubscription(
            id: "sub-\(id)",
            source: SourceIdentity(id: "source-\(id)", kind: kind, canonicalURL: "https://example.com/\(id).xml", host: "example.com", title: id),
            state: state, createdAt: base
        )
    }

    private func entry(_ id: String, in show: String, day: Int, state: FeedEntryState = .unseen) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: "sub-\(show)", canonicalURL: "https://example.com/\(id)", title: id,
            publishedAt: base.addingTimeInterval(Double(day) * 86_400), state: state
        )
    }

    private func pick(_ sources: [String], _ subs: [FeedSubscription], _ entries: [FeedEntry]) -> String? {
        FirstRunListenChoice.entry(forPickedSourceIds: sources, subscriptions: subs, entries: entries)?.id
    }

    func testPlaysTheNewestEpisodeOfTheFirstPick() {
        let subs = [show("a"), show("b")]
        let entries = [entry("a-old", in: "a", day: 1), entry("a-new", in: "a", day: 5), entry("b-newest", in: "b", day: 9)]
        XCTAssertEqual(pick(["source-a", "source-b"], subs, entries), "a-new", "the first pick wins even when a later one is newer")
        XCTAssertEqual(pick(["source-b", "source-a"], subs, entries), "b-newest")
    }

    func testANewsletterPickedFirstPlaysItsLatestPostAheadOfAShow() {
        let subs = [show("pod"), show("letter", kind: .articleFeed)]
        let entries = [entry("ep", in: "pod", day: 9), entry("post-1", in: "letter", day: 2), entry("post-2", in: "letter", day: 4)]
        XCTAssertEqual(pick(["source-letter", "source-pod"], subs, entries), "post-2")
    }

    func testAPickWithNothingToPlayFallsThroughToTheNextPick() {
        let subs = [show("empty"), show("played"), show("good")]
        let entries = [entry("p1", in: "played", day: 3, state: .imported), entry("g1", in: "good", day: 1)]
        XCTAssertEqual(pick(["source-empty", "source-played", "source-good"], subs, entries), "g1")
    }

    func testNoPlayablePickIsNilSoTheWelcomeSamplePlays() {
        XCTAssertNil(pick([], [show("a")], [entry("a1", in: "a", day: 1)]), "nothing picked")
        XCTAssertNil(pick(["source-a"], [show("a")], []), "picked, but the feed has no episodes yet")
        XCTAssertNil(pick(["source-gone"], [show("a")], [entry("a1", in: "a", day: 1)]), "picked then unfollowed")
    }

    func testADismissedEpisodeIsNotPlayed() {
        let subs = [show("a")]
        let entries = [entry("a-new", in: "a", day: 5, state: .dismissed), entry("a-old", in: "a", day: 1)]
        XCTAssertEqual(pick(["source-a"], subs, entries), "a-old")
    }
}
