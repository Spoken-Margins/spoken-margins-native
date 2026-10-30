import XCTest
@testable import SessionKit

/// The follow offer, the suggestion card and the Follow tap decide from an item's link, media type, source and media
/// address, so they read the item's summary, not its text (#2506). Each decision must come out the same for the summary
/// as for the whole item it was cut from.
final class FollowDecisionsFromSummaryTests: XCTestCase {
    private let followed = [
        FeedSubscription(
            id: "subscription-noahpinion",
            source: SourceIdentity(id: "source-noahpinion", kind: .articleFeed, canonicalURL: "https://www.noahpinion.blog/feed", host: "www.noahpinion.blog", title: "Noahpinion")
        )
    ]

    private func item(
        id: String = "article", mediaType: String = "text", link: String? = "https://example.com/p/post",
        referenceType: String? = "url", sourceURL: String? = nil, sourceTitle: String? = nil, mediaURL: String? = nil
    ) -> Item {
        var item = Item(id: id, title: "A post", mediaType: mediaType, text: String(repeating: "Long text. ", count: 5_000), externalReference: link, status: "ready", externalReferenceType: referenceType)
        item.sourceURL = sourceURL
        item.sourceTitle = sourceTitle
        item.media = mediaURL.map { ItemMedia(sourceType: .remoteStream, url: $0) }
        return item
    }

    /// Neighbouring cases: every branch of the discovery rules, a followed site, and look-alikes of each.
    private var table: [Item] {
        [
            item(),
            item(link: "http://example.com/p/post"),
            item(link: "https://example.com/p/post", sourceURL: "https://example.com/feed"),
            item(link: nil, sourceURL: "https://example.com/feed"),
            item(link: nil),
            item(link: "  https://example.com/p/post  "),
            item(mediaType: "podcast", mediaURL: "https://example.com/audio.mp3"),
            item(mediaType: "pdf"),
            item(referenceType: "file"),
            item(referenceType: "epub"),
            item(referenceType: "spoken_margins_package"),
            item(referenceType: "URL"),
            item(id: ListeningEdition.itemIDPrefix + "x"),
            item(link: "https://www.noahpinion.blog/p/a-post"),
            item(link: "https://blog.noahpinion.blog/p/a-post"),
            item(link: "https://example.com/p/post", sourceTitle: "noahpinion"),
            item(link: "https://example.com/p/post", sourceTitle: ""),
        ]
    }

    func testTheDiscoveryLinkIsTheSameFromTheSummary() {
        for original in table {
            XCTAssertEqual(
                ManualFollowPolicy.discoveryURL(for: LibraryItemSummary(original)),
                ManualFollowPolicy.discoveryURL(for: original),
                "\(original.id) \(original.externalReference ?? "nil") \(original.externalReferenceType ?? "nil")"
            )
        }
    }

    func testAlreadyFollowedIsTheSameFromTheSummary() {
        for original in table {
            for subscriptions in [followed, []] {
                XCTAssertEqual(
                    FollowedSourceMatching.isItemAlreadyFollowed(LibraryItemSummary(original), subscriptions: subscriptions),
                    FollowedSourceMatching.isItemAlreadyFollowed(original, subscriptions: subscriptions),
                    "\(original.externalReference ?? "nil") with \(subscriptions.count) followed"
                )
            }
        }
    }

    func testTheDiagnosticForAFailedDiscoveryIsTheSameFromTheSummary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for original in table {
            XCTAssertEqual(
                FollowedSourceMatching.discoveryDiagnostic(item: LibraryItemSummary(original), candidates: nil, failure: "none:empty", subscriptions: followed, at: now),
                FollowedSourceMatching.discoveryDiagnostic(item: original, candidates: nil, failure: "none:empty", subscriptions: followed, at: now),
                original.externalReference ?? "nil"
            )
        }
    }

    func testTheSameOriginCheckSeesTheSameChangesFromTheSummary() {
        let base = item(link: "https://example.com/p/post", sourceURL: "https://example.com/feed", mediaURL: "https://example.com/audio.mp3")
        let changes = [
            base,
            item(link: "https://example.com/p/post", sourceURL: "https://example.com/feed", sourceTitle: "renamed", mediaURL: "https://example.com/audio.mp3"),
            item(link: "https://example.com/p/post", sourceURL: "https://other.example/feed", mediaURL: "https://example.com/audio.mp3"),
            item(link: "https://example.com/p/other", sourceURL: "https://example.com/feed", mediaURL: "https://example.com/audio.mp3"),
            item(link: "https://example.com/p/post", sourceURL: "https://example.com/feed", mediaURL: "https://example.com/other.mp3"),
            item(link: "https://example.com/p/post", sourceURL: "https://example.com/feed", mediaURL: nil),
            item(link: "https://example.com/p/post", sourceURL: nil, mediaURL: "https://example.com/audio.mp3"),
        ]
        for current in changes {
            XCTAssertEqual(
                SourceFollowSuggestionPolicy.hasSameOrigin(LibraryItemSummary(base), LibraryItemSummary(current)),
                SourceFollowSuggestionPolicy.hasSameOrigin(base, current)
            )
        }
    }
}
