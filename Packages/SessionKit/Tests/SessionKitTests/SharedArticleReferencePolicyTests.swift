import Foundation
import XCTest
import SessionKit
@testable import SessionKitSharing

final class SharedArticleReferencePolicyTests: XCTestCase {
    private func item(_ type: SharedItemType = .text, url: String?) -> SharedItemIdentity {
        SharedItemIdentity(itemType: type, canonicalURL: url, originalURL: url, title: "An essay")
    }

    func testAnArticleWithAnHTTPSLinkIsFetchable() {
        XCTAssertEqual(
            SharedArticleReferencePolicy.articleURL(for: item(url: "https://Example.com/essays/slow-listening/#notes"))?.absoluteString,
            "https://example.com/essays/slow-listening"
        )
        XCTAssertEqual(
            SharedArticleReferencePolicy.articleURL(for: item(url: "https://example.com/read?id=7"))?.absoluteString,
            "https://example.com/read?id=7"
        )
    }

    func testNeighbouringItemsAreNotFetchedAsArticles() {
        for type in [SharedItemType.podcast, .pdf, .epub, .other] {
            XCTAssertNil(SharedArticleReferencePolicy.articleURL(for: item(type, url: "https://example.com/a")), "\(type)")
        }
        for link in [nil, "", " ", "http://example.com/a", "ftp://example.com/a", "file:///tmp/a.txt", "https://", "not a url", "javascript:alert(1)"] as [String?] {
            XCTAssertNil(SharedArticleReferencePolicy.articleURL(for: item(url: link)), link ?? "nil")
        }
    }

    func testAFetchedPageThatEndedElsewhereIsNotTheSharedArticle() {
        let shared = item(url: "https://news.example.com/story")
        let text = "The story text."
        // Same page, however the address was written.
        for landed in ["https://news.example.com/story", "https://NEWS.example.com/story/", "https://news.example.com/story#top"] {
            XCTAssertTrue(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(shared, fetchedURL: landed, fetchedText: text, contentFormat: .markdown), landed)
        }
        // A consent wall, a sign-in page, another host, a different path or query, a downgraded scheme or no address.
        for landed in [
            "https://consent.yahoo.com/collectConsent?next=story",
            "https://news.example.com/login?next=/story",
            "https://m.news.example.com/story",
            "https://news.example.com/story?page=2",
            "http://news.example.com/story",
            "",
        ] {
            XCTAssertFalse(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(shared, fetchedURL: landed, fetchedText: "Before you continue", contentFormat: .markdown), landed)
        }
    }

    func testARedirectedPageWithThePacketsTextIsStillTheSharedArticle() {
        let text = "The story text, as the sender saw it."
        let shared = SharedItemIdentity(
            itemType: .text,
            canonicalURL: "https://news.example.com/story",
            title: "An essay",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text)
        )
        XCTAssertTrue(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(
            shared, fetchedURL: "https://m.news.example.com/story", fetchedText: text, contentFormat: .markdown
        ))
        XCTAssertFalse(SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(
            shared, fetchedURL: "https://m.news.example.com/story", fetchedText: "Before you continue", contentFormat: .markdown
        ))
    }

    // MARK: - The check and the import judge a page the same way (#1259)

    private let sender = "https://news.example.com/story"

    /// What the sender's app stored for the page, and so what their packet carries.
    private func storedItem(url: String, markdown: String) throws -> Item {
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "browser", displayName: "Browser", capabilities: ["sync": ["canonical_persistence"]]),
            repository: InMemorySessionRepository()
        )
        let handoff = BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: url, title: "An essay"),
            text: markdown,
            contentFormat: .markdown,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
        return try engine.importBrowserTextInBackground(handoff)
    }

    private func packet(url: String, markdown: String) throws -> SharedItemIdentity {
        SharedItemIdentityBuilder.exportIdentity(for: try storedItem(url: url, markdown: markdown), draftEditionDigests: [])
    }

    /// The check's answer, and the import's own answer for the same page: import it and ask the matcher the app
    /// asks once the Margins are saved. The two must agree for every page.
    private func verdicts(
        _ shared: SharedItemIdentity, landedAt url: String, markdown: String
    ) throws -> (check: Bool, importMatches: Bool) {
        let check = SharedArticleReferencePolicy.fetchedPageIsTheSharedArticle(
            shared, fetchedURL: url, fetchedText: markdown, contentFormat: .markdown
        )
        let imported = try storedItem(url: url, markdown: markdown)
        return (check, ImportedItemResolver.canRepresentSameWork(shared, SharedItemIdentityBuilder.localIdentity(for: imported)))
    }

    func testTheCheckAgreesWithTheImportForEveryWayTheAddressCanMove() throws {
        let original = "The story text, as the sender saw it."
        let other = "Before you continue"
        // (the packet's address, the address the reader ended on, whether the address alone makes it the article)
        let rows: [(String, String, Bool)] = [
            ("https://news.example.com/story?ref=x", "https://news.example.com/story?ref=x", true),
            ("https://news.example.com/story?ref=x", "https://news.example.com/story/?ref=x", false),
            ("https://news.example.com/story?ref=x&a=1", "https://news.example.com/story/?ref=x&a=1", false),
            ("https://news.example.com/story", "https://news.example.com/story/", true),
            ("https://news.example.com/story", "https://news.example.com/story//", true),
            ("https://news.example.com/story/", "https://news.example.com/story", true),
            ("https://news.example.com/story", "https://news.example.com/story#top", true),
            ("https://news.example.com/story?ref=x", "https://news.example.com/story?ref=x#top", true),
            ("https://news.example.com/story", "https://NEWS.example.com/story", true),
            ("https://news.example.com/story", "HTTPS://news.example.com/story", true),
            ("https://news.example.com/story", "https://www.news.example.com/story", false),
            ("https://news.example.com/story", "https://m.news.example.com/story", false),
            ("https://news.example.com/story", "http://news.example.com/story", false),
            ("https://news.example.com/story?a=1&b=2", "https://news.example.com/story?b=2&a=1", false),
            ("https://news.example.com/story", "https://news.example.com/story?utm=x", false),
            ("https://news.example.com/story", "https://news.example.com/Story", false),
            ("https://news.example.com/story", "https://news.example.com/story-2", false),
            ("https://news.example.com/story", "https://news.example.com/stories", false),
            ("https://news.example.com/story", "https://news.example.com/story/extra", false),
            ("https://news.example.com/story", "https://news.example.com.evil.test/story", false),
            ("https://news.example.com/story", "https://consent.news.example.com/story", false),
            ("https://news.example.com/story", "", false),
        ]
        for (packetURL, landed, sameAddress) in rows {
            let shared = try packet(url: packetURL, markdown: original)
            // The text differs: only the address can make it the article.
            let byAddress = try verdicts(shared, landedAt: landed, markdown: other)
            XCTAssertEqual(byAddress.check, sameAddress, "\(packetURL) -> \(landed), different text")
            XCTAssertEqual(byAddress.check, byAddress.importMatches, "check and import disagree: \(packetURL) -> \(landed), different text")
            // The text is the packet's: it is the article wherever the redirect went.
            let byText = try verdicts(shared, landedAt: landed, markdown: original)
            XCTAssertTrue(byText.check, "\(packetURL) -> \(landed), same text")
            XCTAssertEqual(byText.check, byText.importMatches, "check and import disagree: \(packetURL) -> \(landed), same text")
        }
    }

    func testAPageWithImageAndTimestampLinesIsTheArticleAfterTheAddressMoved() throws {
        let page = """
        # Slow listening

        ![The hero image](https://news.example.com/hero.jpg)

        The first paragraph of the essay.

        Timestamps
        00:00 - Intro
        01:20 - The first idea

        The second paragraph, after the show notes.

        ![](https://news.example.com/chart.png)
        """
        let shared = try packet(url: sender, markdown: page)
        // The sender's stored text has none of those lines, so a hash of the page as fetched cannot match it.
        let stored = try XCTUnwrap(try storedItem(url: sender, markdown: page).text)
        XCTAssertFalse(stored.contains("hero"))
        XCTAssertFalse(stored.contains("01:20"))
        let moved = try verdicts(shared, landedAt: "https://amp.news.example.com/story", markdown: page)
        XCTAssertTrue(moved.check)
        XCTAssertTrue(moved.importMatches)
        // The same page with other words is still not the article.
        let changed = try verdicts(shared, landedAt: "https://amp.news.example.com/story", markdown: page.replacingOccurrences(of: "second", with: "third"))
        XCTAssertFalse(changed.check)
        XCTAssertFalse(changed.importMatches)
    }

    func testTheImportsLinkCleaningDoesNotMakeAMovedPageLookDifferent() throws {
        // The import removes addresses written in the text, and the sender's hash is over that result.
        let page = "The economy grew in Q3. See example.net/path and https://example.com for the data."
        let shared = try packet(url: sender, markdown: page)
        XCTAssertNotEqual(try storedItem(url: sender, markdown: page).text, page, "the page has to be one the cleaning changes")
        let moved = try verdicts(shared, landedAt: "https://m.news.example.com/story", markdown: page)
        XCTAssertTrue(moved.check)
        XCTAssertTrue(moved.importMatches)
    }

    func testAbbreviationsAndNumbersDoNotChangeWhatTheImportStores() throws {
        // Answers #1259's question: the import keeps these words as written, so they cannot make hashes differ.
        let page = "The U.S. economy grew 3.5% in Q3, i.e. 12 points, at 9 a.m. on Dr. Lee's 2nd call."
        let stored = try XCTUnwrap(try storedItem(url: sender, markdown: page).text)
        XCTAssertEqual(stored, page)
        let shared = try packet(url: sender, markdown: page)
        let moved = try verdicts(shared, landedAt: "https://m.news.example.com/story", markdown: page)
        XCTAssertTrue(moved.check)
        XCTAssertTrue(moved.importMatches)
    }

    func testAFrontMatterSourceLineIsTheAddressTheImportKeeps() throws {
        let body = "The story text, as the sender saw it."
        let shared = try packet(url: sender, markdown: body)
        // The reader ended on the packet's address, but the import will keep another one and different words:
        // the Margins would not play, so the page is not the article.
        let elsewhere = "---\nsource: https://other.example.com/x\n---\nThe story text, but not the one that was shared."
        let wrongSource = try verdicts(shared, landedAt: sender, markdown: elsewhere)
        XCTAssertFalse(wrongSource.check)
        XCTAssertFalse(wrongSource.importMatches)
        // The reader ended elsewhere, but the page names the packet's address: the import keeps that one.
        let named = "---\nsource: \(sender)\n---\nThe story text, as edited since."
        let namesIt = try verdicts(shared, landedAt: "https://amp.news.example.com/story", markdown: named)
        XCTAssertTrue(namesIt.check)
        XCTAssertTrue(namesIt.importMatches)
        // Front matter around the packet's own words changes nothing.
        let wrapped = try verdicts(shared, landedAt: "https://other.example.com/x", markdown: "---\nsource: https://other.example.com/x\n---\n\(body)")
        XCTAssertTrue(wrapped.check)
        XCTAssertTrue(wrapped.importMatches)
    }

    func testThePolicyBuildsTheIdentityTheImportStores() throws {
        let pages: [(String, String)] = [
            ("https://news.example.com/story", "Plain text, no markup."),
            ("https://news.example.com/story/", "# Title\n\n![img](https://x.test/a.png)\n\nBody with **bold** and `code`.\n\n> Quoted."),
            ("https://news.example.com/story?ref=x", "Timestamps\n00:00 - Intro\n\nBody after the notes. The U.S. grew 3.5%."),
            ("https://news.example.com/story", "---\nsource: \"https://elsewhere.example.com/y\"\ntitle: T\n---\nBody."),
        ]
        for (url, markdown) in pages {
            let stored = SharedItemIdentityBuilder.localIdentity(for: try storedItem(url: url, markdown: markdown))
            let built = try XCTUnwrap(SharedArticleReferencePolicy.importedIdentity(fetchedURL: url, fetchedText: markdown, contentFormat: .markdown))
            XCTAssertEqual(built.normalizedContentSHA256, stored.normalizedContentSHA256, markdown)
            XCTAssertEqual(built.exactEditionSHA256, stored.exactEditionSHA256, markdown)
            XCTAssertEqual(built.canonicalURL, stored.canonicalURL, markdown)
            XCTAssertEqual(built.itemType, stored.itemType, markdown)
        }
        XCTAssertNil(SharedArticleReferencePolicy.importedIdentity(fetchedURL: sender, fetchedText: " \n ", contentFormat: .markdown))
    }
}
