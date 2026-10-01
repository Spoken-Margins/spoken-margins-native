import Foundation
import XCTest
@testable import SessionKit

/// #485: Following filters by kind and subject, and hides a subject, from I2's catalog tags.
final class FollowingFilterTests: XCTestCase {
    private let catalog = SourceCatalog(
        schemaVersion: SourceCatalog.currentSchemaVersion,
        catalogId: "test",
        contentVersion: 1,
        title: "Test",
        generatedAt: "2026-09-30T00:00:00Z",
        locale: "en-US",
        provenance: [],
        subjects: [
            SourceCatalogSubject(id: "science", title: "Science"),
            SourceCatalogSubject(id: "news", title: "News"),
            SourceCatalogSubject(id: "comedy", title: "Comedy"),
        ],
        starterRows: nil,
        entries: [
            SourceCatalogEntry(id: "daily", kind: .podcastFeed, contentKind: .podcast, title: "The Daily",
                               feedURL: "https://feeds.example.com/daily.xml", subjects: ["news"], provenanceIds: []),
            SourceCatalogEntry(id: "lab", kind: .articleFeed, contentKind: .newsletter, title: "Lab Notes",
                               feedURL: "https://lab.example.org/feed", subjects: ["science", "news"], provenanceIds: []),
        ]
    )

    private func source(_ kind: SourceIdentityKind, _ url: String) -> SourceIdentity {
        SourceIdentity(id: url, kind: kind, canonicalURL: url, host: URL(string: url)?.host ?? "")
    }

    func testACatalogMatchGivesTheEntrysKindAndSubjects() {
        // Matched the way the drawer matches: scheme and host fold, a trailing slash is ignored.
        let category = FollowedSourceCategory.of(source(.articleFeed, "http://LAB.example.org/feed/"), catalog: catalog)
        XCTAssertEqual(category, FollowedSourceCategory(contentKind: .newsletter, subjects: ["science", "news"]))
        XCTAssertEqual(category.primarySubject, "science")
    }

    func testWithoutACatalogMatchAPodcastFeedIsAPodcastWithNoSubjects() {
        XCTAssertEqual(FollowedSourceCategory.of(source(.podcastFeed, "https://feeds.example.com/other.xml"), catalog: catalog),
                       FollowedSourceCategory(contentKind: .podcast))
        XCTAssertEqual(FollowedSourceCategory.of(source(.podcastFeed, "https://feeds.example.com/daily.xml"), catalog: nil),
                       FollowedSourceCategory(contentKind: .podcast), "no catalog loaded yet")
    }

    func testAnArticleFeedOrWebsiteWithoutAMatchIsAnArticle() {
        XCTAssertEqual(FollowedSourceCategory.of(source(.articleFeed, "https://blog.example.net/rss"), catalog: catalog),
                       FollowedSourceCategory(contentKind: .article))
        XCTAssertEqual(FollowedSourceCategory.of(source(.website, "https://site.example.net"), catalog: catalog),
                       FollowedSourceCategory(contentKind: .article))
    }

    func testCategoriesForManySubscriptionsMatchOneAtATime() {
        let subscriptions = [
            FeedSubscription(id: "a", source: source(.podcastFeed, "https://FEEDS.example.com/daily.xml/")),
            FeedSubscription(id: "b", source: source(.articleFeed, "https://lab.example.org/feed")),
            FeedSubscription(id: "c", source: source(.podcastFeed, "https://feeds.example.com/other.xml")),
            FeedSubscription(id: "d", source: source(.website, "https://site.example.net")),
        ]
        let categories = FollowedSourceCategory.bySubscription(subscriptions, catalog: catalog)
        XCTAssertEqual(categories.count, 4)
        for subscription in subscriptions {
            XCTAssertEqual(categories[subscription.id], FollowedSourceCategory.of(subscription.source, catalog: catalog), subscription.id)
        }
        XCTAssertEqual(categories["a"]?.subjects, ["news"])
        XCTAssertEqual(FollowedSourceCategory.bySubscription(subscriptions, catalog: nil)["b"], FollowedSourceCategory(contentKind: .article))
    }

    func testWithNothingChosenOrHiddenEveryEntryShows() {
        let filter = FollowingFilter()
        XCTAssertTrue(filter.includes(nil), "Quick Folder files")
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .podcast)))
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .newsletter, subjects: ["science"])))
    }

    func testAKindShowsOnlyThatKind() {
        let filter = FollowingFilter(kind: .podcast)
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .podcast, subjects: ["news"])))
        XCTAssertFalse(filter.includes(FollowedSourceCategory(contentKind: .article)))
        XCTAssertFalse(filter.includes(nil), "a Quick Folder file has no kind")
    }

    func testASubjectShowsEntriesThatListItAnywhere() {
        let filter = FollowingFilter(subject: "news")
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .podcast, subjects: ["news"])))
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .newsletter, subjects: ["science", "news"])))
        XCTAssertFalse(filter.includes(FollowedSourceCategory(contentKind: .podcast)))
        XCTAssertFalse(filter.includes(nil))
    }

    func testAHiddenSubjectHidesEveryEntryThatListsIt() {
        let filter = FollowingFilter(hiddenSubjects: ["news"])
        XCTAssertFalse(filter.includes(FollowedSourceCategory(contentKind: .podcast, subjects: ["news"])))
        XCTAssertFalse(filter.includes(FollowedSourceCategory(contentKind: .newsletter, subjects: ["science", "news"])),
                       "the entries choosing news would show")
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .newsletter, subjects: ["science"])))
        XCTAssertTrue(filter.includes(FollowedSourceCategory(contentKind: .podcast)), "no subject, nothing to hide")
        XCTAssertTrue(filter.includes(nil))
        var chosen = filter
        chosen.subject = "news"
        XCTAssertTrue(chosen.includes(FollowedSourceCategory(contentKind: .podcast, subjects: ["news"])),
                      "choosing a hidden subject shows it")
    }

    func testChipsOfferOnlyKindsAndSubjectsPresent() {
        let categories = [
            FollowedSourceCategory(contentKind: .newsletter, subjects: ["science", "news"]),
            FollowedSourceCategory(contentKind: .podcast, subjects: ["news"]),
            FollowedSourceCategory(contentKind: .podcast),
            FollowedSourceCategory(contentKind: SourceContentKind(rawValue: "audiobook"), subjects: ["history"]),
        ]
        XCTAssertEqual(FollowingFilter.kinds(in: categories), [.podcast, .newsletter, SourceContentKind(rawValue: "audiobook")])
        XCTAssertEqual(FollowingFilter.subjects(in: categories, catalog: catalog).map(\.id), ["science", "news", "history"],
                       "catalog order, then subjects the catalog doesn't list")
        XCTAssertEqual(FollowingFilter.subjects(in: categories, catalog: catalog).map(\.title), ["Science", "News", "history"])
        XCTAssertTrue(FollowingFilter.kinds(in: []).isEmpty)
    }
}
