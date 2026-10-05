import XCTest
@testable import SessionKit

/// #539: diagnostics reported Follow failures for Noahpinion, which the owner follows. An article
/// on the publication's own domain wasn't matched to its followed feed, so discovery ran again.
final class FollowedSourceMatchingTests: XCTestCase {
    private func subscription(_ feedURL: String, title: String? = nil) -> FeedSubscription {
        let host = URL(string: feedURL)?.host ?? "unknown"
        return FeedSubscription(
            id: "subscription-\(feedURL)",
            source: SourceIdentity(id: "source-\(feedURL)", kind: .articleFeed, canonicalURL: feedURL, host: host, title: title)
        )
    }

    private func article(_ link: String, sourceURL: String? = nil, sourceTitle: String? = nil) -> Item {
        var item = Item(id: "article", title: "A post", mediaType: "text", text: "Text.", externalReference: link, status: "ready", externalReferenceType: "url")
        item.sourceURL = sourceURL
        item.sourceTitle = sourceTitle
        return item
    }

    /// A Substack publication on its own domain, followed by its site feed, opened from Safari
    /// (no source link or title on the item).
    func testAnArticleOnAFollowedPublicationsOwnDomainIsAlreadyFollowed() {
        let followed = [subscription("https://www.noahpinion.blog/feed", title: "Noahpinion")]
        XCTAssertTrue(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://www.noahpinion.blog/p/the-economy-in-one-chart?utm_source=substack&utm_medium=email"),
            subscriptions: followed
        ))
        // With or without www., on either side.
        XCTAssertTrue(FollowedSourceMatching.isItemAlreadyFollowed(article("https://noahpinion.blog/p/a-post"), subscriptions: followed))
        XCTAssertTrue(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://www.example.com/2026/09/post"), subscriptions: [subscription("https://example.com/rss/")]
        ))
        // The Library row asks the same question through the other entry point.
        XCTAssertTrue(FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: nil, sourceTitle: nil, sourceReference: "https://www.noahpinion.blog/p/a-post", subscriptions: followed
        ))
    }

    func testAnotherSiteOrAPartialFeedIsNotTheSameSource() {
        let followed = [subscription("https://www.noahpinion.blog/feed")]
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(article("https://www.astralcodexten.com/p/post"), subscriptions: followed))
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(article("https://blog.noahpinion.blog/p/post"), subscriptions: followed))
        // One section's feed doesn't cover the whole site.
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://example.com/sports/post"), subscriptions: [subscription("https://example.com/category/politics/feed")]
        ))
        // Shared hosts: one writer's feed is not every writer's.
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://substack.com/@someone/p-123"), subscriptions: [subscription("https://substack.com/feed")]
        ))
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://medium.com/@writer/post"), subscriptions: [subscription("https://medium.com/feed/@other")]
        ))
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(article("https://www.noahpinion.blog/p/post"), subscriptions: []))
        // An item's own, different source feed decides: a site's podcast feed is not its blog feed.
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://example.com/ep/1", sourceURL: "https://example.com/feed/podcast"),
            subscriptions: [subscription("https://example.com/feed")]
        ))
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://www.noahpinion.blog/p/podcast-episode", sourceURL: "https://feeds.example.com/other-show.xml"),
            subscriptions: followed
        ))
    }

    /// The earlier rules still hold: the source link, then the title when there is no source link.
    func testSourceLinkAndTitleMatchingIsUnchanged() {
        let followed = [subscription("https://feeds.example.com/show.xml", title: "The Show")]
        XCTAssertTrue(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://example.com/episode", sourceURL: "https://feeds.example.com/show.xml/"), subscriptions: followed
        ))
        XCTAssertTrue(FollowedSourceMatching.isItemAlreadyFollowed(article("https://example.com/episode", sourceTitle: "the show"), subscriptions: followed))
        XCTAssertFalse(FollowedSourceMatching.isItemAlreadyFollowed(
            article("https://example.com/episode", sourceURL: "https://feeds.example.com/other.xml", sourceTitle: "The Show"),
            subscriptions: followed
        ))
    }

    func testDiscoveryOfAFollowedFeedSaysAlreadyFollowedNotAnError() {
        let followed = subscription("https://www.noahpinion.blog/feed")
        let found = SourceCandidateEvidence(
            id: "candidate", source: followed.source, evidenceURL: "https://www.noahpinion.blog/p/a-post",
            relation: "publication", confidence: 0.95
        )
        XCTAssertEqual(FollowedSourceMatching.discoveryDiagnostic(candidates: [found], subscriptions: [followed]), "already_followed")
        XCTAssertEqual(FollowedSourceMatching.discoveryDiagnostic(candidates: [found], subscriptions: []), "found:1")
        XCTAssertEqual(FollowedSourceMatching.discoveryDiagnostic(candidates: [], subscriptions: [followed]), "none:empty")
    }

    /// A discovery that failed for a source the listener follows (by now) is not reported as an error.
    func testAFailedDiscoveryForAFollowedSourceSaysAlreadyFollowed() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let item = article("https://www.noahpinion.blog/p/a-post")
        XCTAssertEqual(FollowedSourceMatching.discoveryDiagnostic(
            item: item, candidates: nil, failure: "unavailable:no_feed_candidates",
            subscriptions: [subscription("https://www.noahpinion.blog/feed")], at: at
        ), "already_followed at=2026-09-21T14:13:20Z")
        XCTAssertEqual(FollowedSourceMatching.discoveryDiagnostic(
            item: item, candidates: nil, failure: "none:no_feed_candidates", subscriptions: [], at: at
        ), "none:no_feed_candidates at=2026-09-21T14:13:20Z")
        XCTAssertEqual(FollowedSourceMatching.discoveryDiagnostic(
            item: item, candidates: [], failure: "none:empty", subscriptions: [], at: at
        ), "none:empty at=2026-09-21T14:13:20Z")
    }

    /// Moved out of Gate1AppModel unchanged: the card never offers a feed the listener accepted or
    /// turned off, nor one snoozed or suggested in the last 30 days.
    func testSuggestibleFeedsKeepTheCardsRules() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let decisions: [String: SourceSuggestionDecision] = [
            "accepted": SourceSuggestionDecision(sourceId: "accepted", decision: .accepted),
            "never": SourceSuggestionDecision(sourceId: "never", decision: .neverSuggest),
            "snoozed": SourceSuggestionDecision(sourceId: "snoozed", decision: .notNow, suppressUntil: now.addingTimeInterval(day)),
            "recent": SourceSuggestionDecision(sourceId: "recent", decision: .prompted, lastPromptAt: now.addingTimeInterval(-29 * day)),
            "old": SourceSuggestionDecision(sourceId: "old", decision: .prompted, lastPromptAt: now.addingTimeInterval(-31 * day)),
            "woke": SourceSuggestionDecision(sourceId: "woke", decision: .notNow, suppressUntil: now.addingTimeInterval(-day)),
        ]
        let candidates = ["new", "accepted", "never", "snoozed", "recent", "old", "woke"].map { id in
            SourceCandidateEvidence(
                id: "candidate-\(id)",
                source: SourceIdentity(id: id, kind: .articleFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example"),
                evidenceURL: "https://\(id).example/p/post", relation: "html_alternate", confidence: 0.95
            )
        }
        let offered = FollowedSourceMatching.suggestible(candidates, now: now) { decisions[$0] }
        XCTAssertEqual(offered.map(\.source.id), ["new", "old", "woke"])
    }

    func testFollowDiagnosticsSayWhenTheyWereWritten() {
        let line = FollowedSourceMatching.stampedDiagnostic(
            "no_feed_candidates host=example.com steps=none", at: Date(timeIntervalSince1970: 1_790_000_000)
        )
        XCTAssertEqual(line, "no_feed_candidates host=example.com steps=none at=2026-09-21T14:13:20Z")
    }
}
