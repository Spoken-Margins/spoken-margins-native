import XCTest
@testable import SessionKit

/// #4672 PR 3: "Follow this show" once, at the end of the item a friend's file or link opened on a first launch.
final class FirstLaunchArrivalTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "first-launch-arrival-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func candidate(_ id: String, relation: String = "html_alternate", title: String? = nil) -> SourceCandidateEvidence {
        SourceCandidateEvidence(
            id: "candidate-\(id)",
            source: SourceIdentity(id: id, kind: .podcastFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: title ?? id),
            evidenceURL: "https://\(id).example/episode", relation: relation, confidence: 1
        )
    }

    // MARK: the stored arrival item

    func testTheArrivalItemIsStoredOnceAndSurvivesARebuild() {
        var arrival = FirstLaunchArrival(defaults: defaults)
        XCTAssertNil(arrival.itemId)
        XCTAssertTrue(arrival.recordItem("friend-episode"))
        XCTAssertEqual(FirstLaunchArrival(defaults: defaults).itemId, "friend-episode", "kept across a relaunch")
        XCTAssertFalse(arrival.recordItem("second-friend-item"), "a second arrival does not replace the first")
        XCTAssertEqual(FirstLaunchArrival(defaults: defaults).itemId, "friend-episode")
        XCTAssertEqual(defaults.string(forKey: "firstLaunchArrivalItemIdV1"), "friend-episode")
    }

    func testWhichItemsCountAsTheArrivalItem() {
        let rows: [(String, String?, String, Bool)] = [
            ("nothing stored", nil, "friend-episode", false),
            ("the stored item", "friend-episode", "friend-episode", true),
            ("another item", "friend-episode", "own-article", false),
            ("a lookalike id", "friend-episode", "Friend-Episode", false),
            ("a prefix of it", "friend-episode", "friend", false),
            ("trailing space", "friend-episode", "friend-episode ", false),
            ("empty", "friend-episode", "", false),
        ]
        for (name, stored, asked, expected) in rows {
            let suite = "arrival-rows-\(UUID().uuidString)"
            let local = UserDefaults(suiteName: suite)!
            defer { local.removePersistentDomain(forName: suite) }
            var arrival = FirstLaunchArrival(defaults: local)
            if let stored { _ = arrival.recordItem(stored) }
            XCTAssertEqual(arrival.isArrivalItem(asked), expected, name)
        }
    }

    func testAnEmptyItemIdIsNotRecorded() {
        var arrival = FirstLaunchArrival(defaults: defaults)
        XCTAssertFalse(arrival.recordItem(""))
        XCTAssertNil(arrival.itemId)
        XCTAssertFalse(arrival.isArrivalItem(""), "an empty id never matches a missing record")
    }

    // MARK: when the card shows

    func testTheCardShowsOnlyWhenEveryConditionHolds() {
        func offer(isArrivalItem: Bool = true, finished: Bool = true, canFollow: Bool = true,
                   decisionExists: Bool = false, alreadyOffered: Bool = false) -> Bool {
            FirstLaunchArrival.shouldOfferFollow(
                isArrivalItem: isArrivalItem, finished: finished, canFollow: canFollow,
                decisionExists: decisionExists, alreadyOffered: alreadyOffered
            )
        }
        XCTAssertTrue(offer())
        XCTAssertFalse(offer(isArrivalItem: false), "an item the listener chose themselves")
        XCTAssertFalse(offer(finished: false), "mid-episode")
        XCTAssertFalse(offer(canFollow: false), "no feed found, a PDF, or offline")
        XCTAssertFalse(offer(decisionExists: true), "the listener already answered for this show")
        XCTAssertFalse(offer(alreadyOffered: true), "once")
    }

    func testTheOfferIsSpentOnceMarkedAndStaysSpentAcrossARebuild() {
        var arrival = FirstLaunchArrival(defaults: defaults)
        XCTAssertFalse(arrival.hasOffered)
        arrival.markOffered()
        XCTAssertTrue(arrival.hasOffered)
        XCTAssertTrue(FirstLaunchArrival(defaults: defaults).hasOffered)
        XCTAssertTrue(defaults.bool(forKey: "arrivalFollowOfferedV1"))
        XCTAssertFalse(
            FirstLaunchArrival.shouldOfferFollow(
                isArrivalItem: true, finished: true, canFollow: true, decisionExists: false,
                alreadyOffered: FirstLaunchArrival(defaults: defaults).hasOffered
            )
        )
    }

    func testDecidingNotToShowTheCardDoesNotSpendTheOffer() {
        let arrival = FirstLaunchArrival(defaults: defaults)
        let shown = FirstLaunchArrival.shouldOfferFollow(
            isArrivalItem: true, finished: true, canFollow: false, decisionExists: false, alreadyOffered: arrival.hasOffered
        )
        XCTAssertFalse(shown)
        XCTAssertFalse(arrival.hasOffered, "offline: no card, so a later finish on a network still offers it")
    }

    // MARK: which show the card names

    func testWhichFeedsTheCardCanFollowInOneTap() {
        func target(mediaType: String, candidates: [SourceCandidateEvidence]) -> String? {
            FirstLaunchArrival.followTarget(
                from: ManualFollowPolicy.offer(itemId: "item", mediaType: mediaType, candidates: candidates)
            )?.source.id
        }
        XCTAssertEqual(target(mediaType: "podcast", candidates: [candidate("show")]), "show", "a podcast episode")
        XCTAssertEqual(target(mediaType: "text", candidates: [candidate("blog")]), "blog", "an article")
        XCTAssertNil(target(mediaType: "pdf", candidates: []), "a PDF has no feed")
        XCTAssertNil(target(mediaType: "podcast", candidates: []), "discovery found nothing")
        XCTAssertNil(
            target(mediaType: "podcast", candidates: [candidate("a"), candidate("b")]),
            "two feeds open a chooser, which a one-tap card can't"
        )
        XCTAssertNil(
            target(mediaType: "text", candidates: [candidate("profile", relation: SourceCandidateEvidence.substackProfileRelation)]),
            "a Substack profile needs the listener to confirm"
        )
        XCTAssertNil(FirstLaunchArrival.followTarget(from: nil), "no offer yet, e.g. offline")
    }

    func testTheCardNamesTheShowByTitleOrHost() {
        XCTAssertEqual(candidate("show", title: "The Show").displayName, "The Show")
        XCTAssertEqual(candidate("untitled", title: "  ").displayName, "untitled.example")
    }

    // MARK: Not now

    func testNotNowHoldsThisShowBackForFourteenDaysLikeTheSuggestionCard() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let decision = FirstLaunchArrival.notNowDecision(for: candidate("show"), now: now) { _ in nil }
        XCTAssertEqual(decision.sourceId, "show")
        XCTAssertEqual(decision.decision, .notNow)
        XCTAssertEqual(decision.decidedAt, now)
        XCTAssertEqual(decision.suppressUntil, now.addingTimeInterval(14 * 24 * 60 * 60))
    }
}
