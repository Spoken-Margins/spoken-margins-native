import XCTest
@testable import SessionKit

/// #994: when the "follow this source" card may appear and what the listener's answer saves.
/// The rules used to sit in Gate1AppModel, where the 25 percent threshold was written twice.
final class SourceFollowSuggestionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func candidate(_ id: String) -> SourceCandidateEvidence {
        SourceCandidateEvidence(
            id: "candidate-\(id)",
            source: SourceIdentity(id: id, kind: .articleFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: id),
            evidenceURL: "https://\(id).example/article", relation: "html_alternate", confidence: 1
        )
    }

    private func article(
        sourceURL: String? = "https://example.com/feed",
        externalReference: String? = "https://example.com/article",
        mediaURL: String? = "https://example.com/audio.mp3"
    ) -> Item {
        var item = Item(id: "article", title: "A post", mediaType: "text", text: "Text.", externalReference: externalReference, status: "ready", externalReferenceType: "url")
        item.sourceURL = sourceURL
        item.media = mediaURL.map { ItemMedia(sourceType: .remoteStream, url: $0) }
        return item
    }

    // MARK: Engagement

    func testThresholdIsCrossedAtTwentyFivePercentAndNotBefore() {
        XCTAssertEqual(SourceFollowSuggestionPolicy.engagementThresholdPercent, 25)
        XCTAssertFalse(SourceFollowSuggestionPolicy.crossedEngagementThreshold(previous: 23, current: 24))
        XCTAssertTrue(SourceFollowSuggestionPolicy.crossedEngagementThreshold(previous: 24, current: 25))
        // A seek can jump over the line in one tick.
        XCTAssertTrue(SourceFollowSuggestionPolicy.crossedEngagementThreshold(previous: 10, current: 60))
        // Already past it, or going back: nothing new to ask.
        XCTAssertFalse(SourceFollowSuggestionPolicy.crossedEngagementThreshold(previous: 25, current: 26))
        XCTAssertFalse(SourceFollowSuggestionPolicy.crossedEngagementThreshold(previous: 40, current: 20))
        XCTAssertFalse(SourceFollowSuggestionPolicy.crossedEngagementThreshold(previous: 0, current: 0))
    }

    func testTwentyFourPercentDoesNotOfferAndTwentyFiveDoes() {
        XCTAssertFalse(SourceFollowSuggestionPolicy.isEngaged(progress: 24, itemHasMargin: false))
        XCTAssertTrue(SourceFollowSuggestionPolicy.isEngaged(progress: 25, itemHasMargin: false))
        XCTAssertTrue(SourceFollowSuggestionPolicy.isEngaged(progress: 100, itemHasMargin: false))
    }

    func testAnItemWithAMarginOffersBelowTheThreshold() {
        XCTAssertTrue(SourceFollowSuggestionPolicy.isEngaged(progress: 0, itemHasMargin: true))
        XCTAssertTrue(SourceFollowSuggestionPolicy.isEngaged(progress: 24, itemHasMargin: true))
    }

    func testEngagementUsesLivePlaybackProgressBeforeLibraryRefresh() {
        var snapshot = SessionSnapshot()
        snapshot.itemId = "active-item"
        snapshot.currentPlaybackProgressPercent = 31

        XCTAssertEqual(
            SourceFollowSuggestionPolicy.engagementProgress(itemId: "active-item", persistedProgress: 4, snapshot: snapshot),
            31
        )
        XCTAssertEqual(
            SourceFollowSuggestionPolicy.engagementProgress(itemId: "different-item", persistedProgress: 18, snapshot: snapshot),
            18
        )
    }

    func testEngagementKeepsTheLargerOfSavedAndLiveProgress() {
        var snapshot = SessionSnapshot()
        snapshot.itemId = "active-item"
        snapshot.currentPlaybackProgressPercent = 10
        XCTAssertEqual(
            SourceFollowSuggestionPolicy.engagementProgress(itemId: "active-item", persistedProgress: 40, snapshot: snapshot),
            40,
            "a restart from the top does not undo progress already saved"
        )
        XCTAssertEqual(
            SourceFollowSuggestionPolicy.engagementProgress(itemId: "active-item", persistedProgress: nil, snapshot: snapshot),
            10
        )
        XCTAssertEqual(
            SourceFollowSuggestionPolicy.engagementProgress(itemId: "different-item", persistedProgress: nil, snapshot: snapshot),
            0,
            "another item's live progress never counts"
        )
    }

    // MARK: Stale origin

    func testAnUnchangedOriginIsNotStale() {
        XCTAssertTrue(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article()))
        var renamed = article()
        renamed.title = "Edited title"
        renamed.sourceTitle = "Some Site"
        XCTAssertTrue(SourceFollowSuggestionPolicy.hasSameOrigin(article(), renamed), "only the origin is compared")
    }

    func testAChangedSourceURLReferenceOrMediaURLIsStale() {
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article(sourceURL: "https://other.example/feed")))
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article(sourceURL: nil)))
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article(externalReference: "https://example.com/other-article")))
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article(externalReference: nil)))
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article(mediaURL: "https://example.com/other.mp3")))
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(), article(mediaURL: nil)))
        XCTAssertFalse(SourceFollowSuggestionPolicy.hasSameOrigin(article(sourceURL: nil), article(sourceURL: "https://example.com/feed")))
    }

    // MARK: Saved records

    func testPromptedRecordsStampDecidedAtAndLastPromptAtWithNow() {
        let records = SourceFollowSuggestionPolicy.promptedDecisions(for: [candidate("alpha"), candidate("bravo")], now: now)
        XCTAssertEqual(records.map(\.id), ["suggestion-alpha", "suggestion-bravo"])
        XCTAssertEqual(records.map(\.sourceId), ["alpha", "bravo"])
        for record in records {
            XCTAssertEqual(record.decision, .prompted)
            XCTAssertEqual(record.decidedAt, now)
            XCTAssertEqual(record.lastPromptAt, now)
            XCTAssertNil(record.suppressUntil)
        }
        XCTAssertTrue(SourceFollowSuggestionPolicy.promptedDecisions(for: [], now: now).isEmpty)
    }

    func testNotNowEndsFourteenDaysAfterNow() {
        XCTAssertEqual(SourceFollowSuggestionPolicy.notNowSuppressionInterval, 14 * day)
        let records = SourceFollowSuggestionPolicy.decisions(for: .notNow, candidates: [candidate("alpha")], now: now, prior: { _ in nil })
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "suggestion-alpha")
        XCTAssertEqual(records[0].decision, .notNow)
        XCTAssertEqual(records[0].decidedAt, now)
        XCTAssertEqual(records[0].suppressUntil, now.addingTimeInterval(14 * day))
    }

    func testNeverHasNoEndDate() {
        let records = SourceFollowSuggestionPolicy.decisions(for: .neverSuggest, candidates: [candidate("alpha")], now: now, prior: { _ in nil })
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "suggestion-alpha")
        XCTAssertEqual(records[0].decision, .neverSuggest)
        XCTAssertEqual(records[0].decidedAt, now)
        XCTAssertNil(records[0].suppressUntil)
    }

    func testAnAnswerKeepsTheEarlierLastPromptAtAndStampsNowWhenThereIsNone() throws {
        let earlier = now.addingTimeInterval(-3 * day)
        let repository = InMemorySessionRepository()
        try repository.saveSourceSuggestionDecision(SourceSuggestionDecision(sourceId: "alpha", decision: .prompted, decidedAt: earlier, lastPromptAt: earlier))
        // A record from before lastPromptAt existed carries none.
        try repository.saveSourceSuggestionDecision(SourceSuggestionDecision(sourceId: "bravo", decision: .prompted, decidedAt: earlier))
        let candidates = [candidate("alpha"), candidate("bravo"), candidate("charlie")]

        for answer in [SourceFollowSuggestionPolicy.Answer.notNow, .neverSuggest] {
            let records = SourceFollowSuggestionPolicy.decisions(for: answer, candidates: candidates, now: now) {
                try? repository.loadSourceSuggestionDecision(sourceId: $0)
            }
            XCTAssertEqual(records.map(\.lastPromptAt), [earlier, now, now], "\(answer)")
        }
    }

    func testDecisionKindsKeepTheirStoredNames() {
        XCTAssertEqual(SourceSuggestionDecisionKind.prompted.rawValue, "prompted")
        XCTAssertEqual(SourceSuggestionDecisionKind.accepted.rawValue, "accepted")
        XCTAssertEqual(SourceSuggestionDecisionKind.notNow.rawValue, "not_now")
        XCTAssertEqual(SourceSuggestionDecisionKind.neverSuggest.rawValue, "never_suggest")
    }

    // MARK: With the 30-day rule

    func testAPromptedFeedIsNotOfferedAgainAndANotNowFeedStaysHidden() throws {
        let repository = InMemorySessionRepository()
        let alpha = candidate("alpha")
        for record in SourceFollowSuggestionPolicy.promptedDecisions(for: [alpha], now: now) {
            try repository.saveSourceSuggestionDecision(record)
        }
        let lookup: (String) throws -> SourceSuggestionDecision? = { try repository.loadSourceSuggestionDecision(sourceId: $0) }
        XCTAssertTrue(try FollowedSourceMatching.suggestible([alpha], now: now.addingTimeInterval(day), decision: lookup).isEmpty)

        let notNow = SourceFollowSuggestionPolicy.decisions(for: .notNow, candidates: [alpha], now: now, prior: { try? lookup($0) })
        for record in notNow { try repository.saveSourceSuggestionDecision(record) }
        XCTAssertTrue(try FollowedSourceMatching.suggestible([alpha], now: now.addingTimeInterval(13 * day), decision: lookup).isEmpty)
        // The 30-day rule still holds it back after the 14 days end; the two windows are separate.
        XCTAssertTrue(try FollowedSourceMatching.suggestible([alpha], now: now.addingTimeInterval(15 * day), decision: lookup).isEmpty)
        XCTAssertEqual(try FollowedSourceMatching.suggestible([alpha], now: now.addingTimeInterval(31 * day), decision: lookup).count, 1)
    }

    func testANeverFeedIsNeverOfferedAgain() throws {
        let repository = InMemorySessionRepository()
        let alpha = candidate("alpha")
        for record in SourceFollowSuggestionPolicy.decisions(for: .neverSuggest, candidates: [alpha], now: now, prior: { _ in nil }) {
            try repository.saveSourceSuggestionDecision(record)
        }
        let lookup: (String) throws -> SourceSuggestionDecision? = { try repository.loadSourceSuggestionDecision(sourceId: $0) }
        XCTAssertTrue(try FollowedSourceMatching.suggestible([alpha], now: now.addingTimeInterval(400 * day), decision: lookup).isEmpty)
    }
}
