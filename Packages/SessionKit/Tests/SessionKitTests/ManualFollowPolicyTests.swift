import XCTest
@testable import SessionKit

/// B2 M1, #243, #280: Follow for articles and podcasts, offered only once a feed is found.
final class ManualFollowPolicyTests: XCTestCase {
    private func candidate(_ title: String?, kind: SourceIdentityKind = .articleFeed, id: String = "source") -> SourceCandidateEvidence {
        SourceCandidateEvidence(
            id: "candidate-\(id)",
            source: SourceIdentity(id: id, kind: kind, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: title),
            evidenceURL: "https://\(id).example/p/post",
            relation: "html_alternate",
            confidence: 0.95
        )
    }

    private func discovers(
        itemId: String = "item-browser-post",
        mediaType: String = "text",
        sourceURL: String? = nil,
        reference: String?,
        referenceType: String? = "url"
    ) -> Bool {
        ManualFollowPolicy.shouldDiscoverFeed(
            itemId: itemId, mediaType: mediaType, sourceURL: sourceURL,
            sourceReference: reference, sourceReferenceType: referenceType
        )
    }

    func testArticlesAndPodcastsWithAnHTTPSLinkAreWorthDiscovering() {
        XCTAssertTrue(discovers(reference: "https://www.astralcodexten.com/p/the-specter-of-neuralese?utm_source=substack"))
        XCTAssertTrue(discovers(sourceURL: "https://garymarcus.substack.com/feed", reference: nil))
        XCTAssertTrue(discovers(mediaType: "podcast", sourceURL: "https://feeds.example.com/show.xml", reference: nil, referenceType: nil))
        XCTAssertTrue(discovers(mediaType: "transcript_backed_media", reference: "https://podcasts.apple.com/us/podcast/id1", referenceType: nil))
    }

    func testItemsWithoutAWebLinkAreNot() {
        XCTAssertFalse(discovers(reference: nil))
        XCTAssertFalse(discovers(reference: "pasted-text"))
        XCTAssertFalse(discovers(reference: "http://example.com/post"))
        // Podcasts used to show Follow even with no link to discover from.
        XCTAssertFalse(discovers(mediaType: "podcast", reference: nil, referenceType: nil))
    }

    /// #280: "it offered me to follow when it was uploaded from a file on my phone". A Markdown
    /// file keeps its front-matter `source:` link as the reference, but the item is the file.
    func testAFileFromThePhoneIsNeverFollowable() {
        XCTAssertFalse(discovers(reference: "https://example.com/clipped-post", referenceType: "file"))
        XCTAssertFalse(discovers(reference: "notes.md", referenceType: "file"))
        XCTAssertFalse(discovers(reference: "https://example.com/book", referenceType: "epub"))
    }

    func testAPDFIsNeverFollowable() {
        XCTAssertFalse(discovers(mediaType: "pdf", reference: "https://arxiv.org/pdf/2401.00001"))
        XCTAssertFalse(discovers(mediaType: "pdf", reference: "paper.pdf", referenceType: "file"))
    }

    func testAListeningEditionIsNeverFollowable() throws {
        let map = #"{"overview":"Brief","scenes":[{"title":"One","description":"Orientation","summary":"Summary","startBlock":1,"endBlock":1}]}"#
        let edition = try ListeningEdition.assemble(
            title: "Edition", sourceURL: "https://www.astralcodexten.com/p/the-specter-of-neuralese",
            text: "Opening line.", generator: "test", mapJSON: map
        )
        XCTAssertTrue(edition.itemID.hasPrefix(ListeningEdition.itemIDPrefix))
        XCTAssertFalse(discovers(itemId: edition.itemID, reference: edition.sourceURL))
    }

    /// #280: a site with no feed (openai.com in the owner's diagnostics) showed Follow, and tapping failed.
    func testNoFeedFoundMeansNoFollow() {
        XCTAssertNil(ManualFollowPolicy.offer(itemId: "article", mediaType: "text", candidates: []))
        XCTAssertNil(ManualFollowPolicy.offer(itemId: "episode", mediaType: "podcast", candidates: []))
    }

    /// #280: the label went from "Follow Publication" to "Follow <name>" ~15 s in, when the
    /// suggestion card replaced the button. One feed is named up front, as the card names it.
    func testOneFeedIsNamedFromTheStart() throws {
        let offer = try XCTUnwrap(ManualFollowPolicy.offer(itemId: "article", mediaType: "text", candidates: [candidate("Astral Codex Ten")]))
        XCTAssertEqual(offer.title, "Follow Astral Codex Ten")
        XCTAssertEqual(offer.followingTitle, "Following Astral Codex Ten…")
        XCTAssertEqual(offer.symbol, "newspaper")
        XCTAssertEqual(offer.itemId, "article")
    }

    /// The suggestion card names a feed by title, else host; the button uses the same rule.
    func testAnUntitledFeedIsNamedByItsHostLikeTheCard() throws {
        let untitled = try XCTUnwrap(ManualFollowPolicy.offer(itemId: "a", mediaType: "text", candidates: [candidate(nil)]))
        XCTAssertEqual(untitled.title, "Follow source.example")
        XCTAssertEqual(untitled.title, "Follow \(candidate(nil).displayName)")
        XCTAssertEqual(candidate("  ").displayName, "source.example")
    }

    /// #243: an article's Follow read "Follow Podcast". Several feeds open a chooser, so the
    /// label names the kind: an article follows its publication, a podcast episode its podcast.
    func testArticlesFollowTheirPublicationNotAPodcast() throws {
        // A Substack feed with audio posts is a podcast feed, but the article still follows a publication.
        let article = try XCTUnwrap(ManualFollowPolicy.offer(
            itemId: "a", mediaType: "text",
            candidates: [candidate("Main", kind: .podcastFeed, id: "one"), candidate("Section", id: "two")]
        ))
        XCTAssertEqual(article.title, "Follow Publication")
        XCTAssertEqual(article.followingTitle, "Following Publication…")
        XCTAssertEqual(article.candidates.count, 2)

        let podcast = try XCTUnwrap(ManualFollowPolicy.offer(
            itemId: "e", mediaType: "podcast",
            candidates: [candidate("One", kind: .podcastFeed, id: "one"), candidate("Two", kind: .podcastFeed, id: "two")]
        ))
        XCTAssertEqual(podcast.title, "Follow Podcast")
        XCTAssertEqual(podcast.symbol, "dot.radiowaves.left.and.right")
    }
}
