import Foundation
import XCTest
import SessionKit
@testable import SessionKitFeeds
import SessionKitPersistence
import SessionKitTestInputs

/// #4461, found on the owner's phone: a followed Substack post imported from its feed had no chapters, so no scenes on
/// its Timeline. The feed's HTML body was flattened to one line, so the headings the importer builds chapters from
/// were gone, although the same post read from its page has them. `substack-zvi-post-with-headings.rss` is the real
/// item for https://thezvi.substack.com/p/jensen-huang-really-liked-selling, with each long paragraph cut to its
/// first sentence.
final class FeedBodyHeadingsTests: XCTestCase {
    private static let post = "https://thezvi.substack.com/p/jensen-huang-really-liked-selling"
    private static let headings = [
        "Table of Contents",
        "The Story That Matters Most",
        "Yes Export Controls Matter and Are Finally Happening",
        "How Far Does This Go?",
        "The First Step Is Admitting You Have a Problem",
        "Somehow People Are Still Defending Jensen Huang",
        "Jensen Huang Wants to Call It a Comeback",
        "On Interim CEO Kress",
        "An Actual Attack on Jensen’s Character",
        "Solve for the New Equilibrium",
        "But This Time They’ve Gone Too Far"
    ]

    private func fixtureItem() throws -> ParsedFeedItem {
        let data = try TestInputs.data(.contracts, "fixtures/feeds/substack-zvi-post-with-headings.rss")
        return try XCTUnwrap(FeedParser().parse(data: data).items.first)
    }

    private func entry(_ item: ParsedFeedItem, withVoice: Bool) -> FeedEntry {
        FeedEntry(
            id: "zvi", subscriptionId: "zvi", canonicalURL: item.url,
            audioURL: withVoice ? "https://substack-video.s3.amazonaws.com/video_upload/post/225210833/tts/x/voice.mp3" : nil,
            title: item.title, bodyWordCount: PublisherAudioDetector.bodyWordCount(of: item),
            fullBody: item.content, publisherNarrationConfirmed: withVoice ? true : nil)
    }

    private func importedChapters(_ handoff: BrowserTextHandoff) throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "feed", displayName: "Feed",
            capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let item = try engine.importBrowserTextInBackground(handoff)
        return try store.loadListeningMap(itemId: item.id)?.chapters.map(\.title) ?? []
    }

    /// The route the owner's post takes once its Substack voice is found (a listener's Add, or a share that matched the feed).
    func testAFollowedPostWithItsVoiceImportsWithOneChapterPerHeading() throws {
        let item = try fixtureItem()
        let handoff = try XCTUnwrap(PublisherAudioDetector.articleHandoff(for: entry(item, withVoice: true)))
        XCTAssertEqual(handoff.contentFormat, .markdown)
        let chapters = try importedChapters(handoff)
        XCTAssertEqual(Array(chapters.suffix(Self.headings.count)), Self.headings, "\(chapters)")
    }

    /// The route a background refresh takes (#2368): no voice found, the feed's own text.
    func testABackgroundFeedImportKeepsTheHeadingsToo() throws {
        let item = try fixtureItem()
        let handoff = try XCTUnwrap(PublisherAudioDetector.feedBodyHandoff(for: entry(item, withVoice: false)))
        let chapters = try importedChapters(handoff)
        XCTAssertEqual(Array(chapters.suffix(Self.headings.count)), Self.headings, "\(chapters)")
    }

    /// A body with no headings, or plain JSON Feed text that merely starts with a hash, is not read as Markdown.
    func testOnlyABodyWithHeadingsIsReadAsMarkdown() {
        func format(_ body: String) -> BrowserTextContentFormat? {
            let entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: Self.post, title: "Post", fullBody: body)
            return PublisherAudioDetector.feedBodyHandoff(for: entry)?.contentFormat
        }
        XCTAssertEqual(format("## Part\n\nText."), .markdown)
        XCTAssertNil(format("Just a paragraph of text."))
        XCTAssertNil(format("# of users grew 10% this year."))
        XCTAssertNil(format("A line.\n- not a heading\n#hashtag"))
    }

    func testTheUpNextPreviewShowsNoHeadingMarks() throws {
        let item = try fixtureItem()
        let preview = try XCTUnwrap(FollowingUpNext.descriptionText(of: entry(item, withVoice: false)))
        XCTAssertFalse(preview.contains("#"), preview)
        XCTAssertFalse(preview.contains("\n"), preview)
    }

    // MARK: Neighbouring inputs

    func testHeadingsBecomeMarkdownLinesWhateverTheirLevelCaseOrContents() {
        let rows: [(html: String, text: String)] = [
            ("<h4>Title</h4><p>Body</p>", "#### Title\n\nBody"),
            ("<p>Before</p><h2>Title</h2><p>After</p>", "Before\n\n## Title\n\nAfter"),
            ("Before<h2>Title</h2>After", "Before\n\n## Title\n\nAfter"),
            ("<H3 CLASS=\"x\">Title</H3><p>Body</p>", "### Title\n\nBody"),
            ("<h2>Two</h2><h6>Six</h6>", "## Two\n\n###### Six"),
            ("<h1>Post title</h1><h2>Part</h2>", "## Post title\n\n## Part"),
            ("<h2>\n  Spaced \n title \n</h2><p>Body</p>", "## Spaced title\n\nBody"),
            ("<h3><a href=\"/x\">Linked</a> &amp; <em>styled</em></h3><p>Body</p>", "### Linked & styled\n\nBody"),
            ("<h2>Don&#8217;t panic</h2><p>Body</p>", "## Don’t panic\n\nBody"),
            ("<h2>First</h2><h2>Second</h2><p>Body</p>", "## First\n\n## Second\n\nBody"),
            ("<h2 id=\"a\">Title<div><button>Link</button></div></h2><p>Body</p>", "## Title Link\n\nBody")
        ]
        for row in rows {
            XCTAssertEqual(FeedArticleBodyText.html(row.html), row.text, row.html)
        }
    }

    func testABodyWithoutHeadingsIsFlattenedAsBefore() {
        let rows: [(html: String, text: String)] = [
            ("<p>One.</p>\n<p>Two &amp; three.</p>", "One. Two & three."),
            ("Plain text only", "Plain text only"),
            ("<h2> </h2><p>Body</p>", "Body"),
            ("<h2><br></h2><p>Body</p>", "Body"),
            ("<p>Mentions &lt;h2&gt;Not a heading&lt;/h2&gt; in text.</p>", "Mentions <h2>Not a heading</h2> in text."),
            ("<p>A hash # and <b>bold</b> stay text.</p>", "A hash # and bold stay text.")
        ]
        for row in rows {
            XCTAssertEqual(FeedArticleBodyText.html(row.html), row.text, row.html)
        }
    }

    func testAStyledParagraphInAHeadingTagStaysRunningText() {
        let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        XCTAssertGreaterThan(long.count, FeedArticleBodyText.maximumHeadingCharacters)
        XCTAssertEqual(FeedArticleBodyText.html("<h2>\(long)</h2><p>Body</p>"), "\(long) Body")
    }

    func testAPrivateUseMarkInTheBodyIsDropped() {
        XCTAssertEqual(FeedArticleBodyText.html("<p>A\u{E000}B</p><h2>Title</h2>"), "AB\n\n## Title")
    }

    func testJSONFeedHTMLBodiesKeepHeadingsAndPlainTextBodiesAreUntouched() throws {
        let json = """
        {"version":"https://jsonfeed.org/version/1.1","title":"Publisher","items":[
        {"id":"html","url":"https://publisher.example/html","content_html":"<h2>Part one</h2><p>Text.</p>"},
        {"id":"plain","url":"https://publisher.example/plain","content_text":"# Not changed\\nText."}]}
        """
        let items = try FeedParser().parse(data: Data(json.utf8)).items
        XCTAssertEqual(items.first { $0.id == "html" }?.content, "## Part one\n\nText.")
        XCTAssertEqual(items.first { $0.id == "plain" }?.content, "# Not changed Text.", "plain text keeps its old path")
    }
}
