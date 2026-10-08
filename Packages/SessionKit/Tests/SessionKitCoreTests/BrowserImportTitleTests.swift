import Foundation
import XCTest
import SessionKit
import SessionKitPersistence

/// A page added from Safari keeps its title as given (#1059). The parser read the title as a file
/// name, so `Notes on v1.5 release` lost `.5 release`, and its `unquote` took the quotes at the ends.
/// Item ids come from the title the importer produced before that was fixed, so pages already in the
/// Library are found again: the ids below were produced by that code (Build 29 and `next` at a0826f06).
final class BrowserImportTitleTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private var engine: SessionEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "test", displayName: "Test", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Row {
        let page: String
        let url: String
        /// The item title now: the page title as given, trimmed.
        let title: String
        /// The item id the old importer made for this page and URL.
        let legacyId: String
    }

    private static let rows = [
        // The four titles from the issue.
        Row(page: "Why I left Google. Part 2", url: "https://example.com/post-0", title: "Why I left Google. Part 2",
            legacyId: "item-browser-why-i-left-google-https-example-com-post-0"),
        Row(page: "Notes on v1.5 release", url: "https://example.com/post-1", title: "Notes on v1.5 release",
            legacyId: "item-browser-notes-on-v1-https-example-com-post-1"),
        Row(page: "A//B testing. Part 2", url: "https://example.com/post-2", title: "A//B testing. Part 2",
            legacyId: "item-browser-a-b-testing-https-example-com-post-2"),
        Row(page: "Ann Lee on X: \"Hello there\"", url: "https://example.com/post-3", title: "Ann Lee on X: \"Hello there\"",
            legacyId: "item-browser-ann-lee-on-x-hello-there-https-example-com-post-"),
        // Neighbours: dots in other places, quotes at either end, Unicode, a trailing slash, padding.
        Row(page: "Section 1.2.3", url: "https://example.com/post-4", title: "Section 1.2.3",
            legacyId: "item-browser-section-1-2-https-example-com-post-4"),
        Row(page: "Hello.", url: "https://example.com/post-5", title: "Hello.",
            legacyId: "item-browser-hello-https-example-com-post-5"),
        Row(page: ".bashrc tips", url: "https://example.com/post-6", title: ".bashrc tips",
            legacyId: "item-browser-bashrc-tips-https-example-com-post-6"),
        Row(page: "Café. Ünïcode — résumé v2.0", url: "https://example.com/post-7", title: "Café. Ünïcode — résumé v2.0",
            legacyId: "item-browser-café-ünïcode-résumé-v2-https-example-com-post-7"),
        Row(page: "Titles about the 'Beatles'", url: "https://example.com/post-8", title: "Titles about the 'Beatles'",
            legacyId: "item-browser-titles-about-the-beatles-https-example-com-post-"),
        Row(page: "\"Quoted\" start", url: "https://example.com/post-9", title: "\"Quoted\" start",
            legacyId: "item-browser-quoted-start-https-example-com-post-9"),
        Row(page: "Why/ How/", url: "https://example.com/post-10", title: "Why/ How/",
            legacyId: "item-browser-why-how-https-example-com-post-10"),
        Row(page: "Plain title", url: "https://example.com/post-11", title: "Plain title",
            legacyId: "item-browser-plain-title-https-example-com-post-11"),
        Row(page: "Dots... and more", url: "https://example.com/post-14", title: "Dots... and more",
            legacyId: "item-browser-dots-https-example-com-post-14"),
        Row(page: "a.b", url: "https://example.com/post-15", title: "a.b",
            legacyId: "item-browser-a-https-example-com-post-15"),
        Row(page: "  Padded v1.5   ", url: "https://example.com/post-16", title: "Padded v1.5",
            legacyId: "item-browser-padded-v1-https-example-com-post-16"),
        Row(page: String(repeating: "Long title. ", count: 30), url: "https://example.com/post-13",
            title: String(repeating: "Long title. ", count: 29) + "Long title.",
            legacyId: "item-browser-long-title-long-title-long-title-long-title-long"),
        // No page title: the host stands in for it, whole (the old code cut `example.com` to `example`).
        Row(page: "", url: "https://example.com/post-12", title: "example.com",
            legacyId: "item-browser-example-https-example-com-post-12"),
    ]

    private func markdownHandoff(_ row: Row, text: String? = nil) -> BrowserTextHandoff {
        BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: row.url, title: row.page),
            text: text ?? "Body paragraph for \(row.url) with enough words to import.",
            contentFormat: .markdown
        )
    }

    func testAMarkdownPageKeepsItsTitleAsGiven() throws {
        for row in Self.rows {
            let item = try engine.importBrowserTextInBackground(markdownHandoff(row))
            XCTAssertEqual(item.title, row.title, "title of \"\(row.page)\"")
            XCTAssertEqual(try store.loadItem(id: item.id).title, row.title, "stored title of \"\(row.page)\"")
        }
    }

    func testItemIdsStayWhatTheOldImporterMade() throws {
        for row in Self.rows {
            XCTAssertEqual(try engine.importBrowserTextInBackground(markdownHandoff(row)).id, row.legacyId, "id of \"\(row.page)\"")
        }
    }

    func testReimportingAPageFindsTheItemAlreadyInTheLibrary() throws {
        for row in Self.rows {
            let first = try engine.importBrowserTextInBackground(markdownHandoff(row))
            XCTAssertEqual(first.id, row.legacyId)
        }
        let before = try store.listItems(includeDeleted: true).count
        XCTAssertEqual(before, Self.rows.count)
        for row in Self.rows {
            XCTAssertEqual(try engine.importBrowserTextInBackground(markdownHandoff(row)).id, row.legacyId, "second import of \"\(row.page)\"")
        }
        XCTAssertEqual(try store.listItems(includeDeleted: true).count, before, "no duplicates")
    }

    func testPlainTextPagesAreUnchanged() throws {
        for row in Self.rows where !row.page.isEmpty {
            let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
                captureMode: .readablePage,
                source: BrowserTextSource(url: row.url, title: row.page),
                text: "Plain body for \(row.url).",
                contentFormat: .plainText
            ))
            XCTAssertEqual(item.title, row.page.trimmingCharacters(in: .whitespaces), "plain text title of \"\(row.page)\"")
        }
    }

    func testAHeadingOrFrontMatterTitleStillWinsAndKeepsItsId() throws {
        let page = Row(page: "Page title v1.5", url: "https://example.com/a", title: "", legacyId: "")
        let heading = try engine.importBrowserTextInBackground(markdownHandoff(page, text: "# Real heading. v2\n\nBody under the heading."))
        XCTAssertEqual(heading.title, "Real heading. v2")
        XCTAssertEqual(heading.id, "item-browser-real-heading-v2-https-example-com-a")

        // The heading equals the page title: the id still comes from the heading, which was never cut.
        let same = Row(page: "Same title v1.5", url: "https://example.com/b", title: "", legacyId: "")
        let sameItem = try engine.importBrowserTextInBackground(markdownHandoff(same, text: "# Same title v1.5\n\nBody under the heading."))
        XCTAssertEqual(sameItem.title, "Same title v1.5")
        XCTAssertEqual(sameItem.id, "item-browser-same-title-v1-5-https-example-com-b")

        let fmPage = Row(page: "Page title v1.5", url: "https://example.com/c", title: "", legacyId: "")
        let frontMatter = try engine.importBrowserTextInBackground(
            markdownHandoff(fmPage, text: "---\ntitle: \"Front matter title\"\n---\n\nBody after front matter.")
        )
        XCTAssertEqual(frontMatter.title, "Front matter title")
        XCTAssertEqual(frontMatter.id, "item-browser-front-matter-title-https-example-com-c")
    }

    func testFileNamesStillLoseTheirExtension() throws {
        XCTAssertEqual(try ObsidianMarkdownParser.parse(fileName: "Notes on v1.5 release.md", contents: "Body.").title, "Notes on v1.5 release")
        XCTAssertEqual(try ObsidianMarkdownParser.parse(fileName: "Article.md", contents: "Body.").title, "Article")
        XCTAssertEqual(try ObsidianMarkdownParser.parse(fileName: "Article", contents: "Body.").title, "Article")
        let page = try ObsidianMarkdownParser.parse(fileName: "v1.5 release", contents: "Body.", fallbackTitle: "v1.5 release")
        XCTAssertEqual(page.title, "v1.5 release")
        XCTAssertTrue(page.titleIsFallback)
        XCTAssertFalse(try ObsidianMarkdownParser.parse(fileName: "Article.md", contents: "Body.").titleIsFallback)
        XCTAssertFalse(try ObsidianMarkdownParser.parse(fileName: "x", contents: "# Heading\n\nBody.", fallbackTitle: "x").titleIsFallback)
    }
}
