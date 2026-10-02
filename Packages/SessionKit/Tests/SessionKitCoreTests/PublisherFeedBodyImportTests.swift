import Foundation
import XCTest
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

final class PublisherFeedBodyImportTests: XCTestCase {
    func testNumericAndNamedFeedEntitiesReachTheImportedArticleAsText() throws {
        let prefix = "Don&#8217;t stop. &ldquo;Read&#x2014;then listen&rdquo; &copy; 2026. &NotEqualTilde; &#x1F600;"
        let expectedPrefix = "Don’t stop. “Read—then listen” © 2026. ≂̸ 😀"
        let words = String(repeating: "The harbour shelters fishing boats. ", count: 130)
        let parsed = try FeedParser().parse(data: Data("""
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Publisher</title><generator>Substack</generator><item>
        <title>Article</title><link>https://publisher.example/p/article</link>
        <enclosure url="https://publisher.example/recording.mp3" type="audio/mpeg"/>
        <content:encoded><![CDATA[<p>\(prefix)</p><p>\(words)</p>]]></content:encoded>
        </item></channel></rss>
        """.utf8))
        let post = try XCTUnwrap(parsed.items.first)
        let entry = FeedEntry(id: "post", subscriptionId: "source", canonicalURL: post.url,
            audioURL: post.audioURL, title: post.title, bodyWordCount: PublisherAudioDetector.bodyWordCount(of: post),
            fullBody: post.content, publisherNarrationConfirmed: true)
        let handoff = try XCTUnwrap(PublisherAudioDetector.articleHandoff(for: entry))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "article", displayName: "Article",
            capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let imported = try engine.importBrowserTextInBackground(handoff)
        let text = try XCTUnwrap(store.loadItem(id: imported.id).text)
        XCTAssertTrue(text.hasPrefix(expectedPrefix), String(text.prefix(130)))
        XCTAssertFalse(text.contains("&#8217;"))
        XCTAssertFalse(text.contains("&ldquo;"))
        XCTAssertFalse(text.contains("&NotEqualTilde;"))
    }

    func testHTMLBodyDecodesOnlyOnceAndPlainJSONBodyKeepsLiteralReferences() throws {
        let json = """
        {"version":"https://jsonfeed.org/version/1.1","title":"Publisher","items":[
        {"id":"html","url":"https://publisher.example/html","content_html":"<p>&amp;copy; &lt;tag&gt; &copy; &#x2019;</p>"},
        {"id":"plain","url":"https://publisher.example/plain","content_text":"&copy; &#8217; are literal references."}]}
        """
        let items = try FeedParser().parse(data: Data(json.utf8)).items
        XCTAssertEqual(items.first { $0.id == "html" }?.content, "&copy; <tag> © ’")
        XCTAssertEqual(items.first { $0.id == "plain" }?.content, "&copy; &#8217; are literal references.")
    }
}
