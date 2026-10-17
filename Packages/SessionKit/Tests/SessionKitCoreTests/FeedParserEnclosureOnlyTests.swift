import Foundation
import XCTest
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #179: following a podcast feed dropped every episode that had audio but no <link>.
final class FeedParserEnclosureOnlyTests: XCTestCase {
    func testRSSEpisodesWithAudioButNoLinkAreKept() throws {
        let parsed = try FeedParser().parse(data: Self.fixture("enclosure-only-episodes.rss"))
        XCTAssertEqual(parsed.items.map(\.title), [
            "Episode 3: No link, GUID and audio",
            "Episode 2: No link, no GUID, audio only",
            "Episode 1: Has a link",
        ])
        guard parsed.items.count == 3 else { return }

        let withGUID = parsed.items[0]
        XCTAssertEqual(withGUID.id, "sm-test-show-ep3", "identity falls back to the GUID")
        XCTAssertEqual(withGUID.audioURL, "https://media.example.com/show/ep3.mp3")
        XCTAssertEqual(withGUID.url, "https://media.example.com/show/ep3.mp3", "with no link, the enclosure is the item's URL")

        let audioOnly = parsed.items[1]
        XCTAssertEqual(audioOnly.id, audioOnly.audioURL, "with no GUID either, identity falls back to the enclosure URL")
    }

    func testItemsWithNeitherLinkNorAudioAreStillDropped() throws {
        let parsed = try FeedParser().parse(data: Self.fixture("enclosure-only-episodes.rss"))
        XCTAssertFalse(parsed.items.contains { $0.title.hasPrefix("Show note") })
        XCTAssertFalse(parsed.items.contains { $0.title.hasPrefix("Trailer") }, "a video enclosure isn't audio")
    }

    func testLinkedItemsKeepTheirIdentitySoFollowedFeedsDontDuplicate() throws {
        let parsed = try FeedParser().parse(data: Self.fixture("enclosure-only-episodes.rss"))
        let linked = try XCTUnwrap(parsed.items.first { $0.title == "Episode 1: Has a link" })
        XCTAssertEqual(linked.id, "sm-test-show-ep1")
        XCTAssertEqual(linked.url, "https://example.com/show/episode-1")

        let noGUID = Data("""
        <rss version="2.0"><channel><title>T</title>
        <item><title>A</title><link>https://example.com/a</link><enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8)
        let item = try XCTUnwrap(try FeedParser().parse(data: noGUID).items.first)
        XCTAssertEqual(item.id, "https://example.com/a", "a linked item without a GUID is still identified by its link")
        XCTAssertEqual(item.url, "https://example.com/a")
    }

    func testAtomEntryWithOnlyAnAudioEnclosureIsKept() throws {
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>
        <entry><title>Audio only</title><id>tag:example.com,2026:1</id><link rel="enclosure" type="audio/mpeg" href="https://example.com/1.mp3"/></entry>
        <entry><title>Nothing</title><id>tag:example.com,2026:2</id></entry>
        </feed>
        """.utf8)
        let parsed = try FeedParser().parse(data: atom)
        XCTAssertEqual(parsed.items.map(\.title), ["Audio only"])
        XCTAssertEqual(parsed.items.first?.id, "tag:example.com,2026:1")
    }

    func testJSONFeedItemWithOnlyAnAudioAttachmentIsKept() throws {
        let json = Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"T","items":[
        {"id":"1","title":"Audio only","attachments":[{"url":"https://example.com/1.mp3","mime_type":"audio/mpeg"}]},
        {"title":"No id, audio only","attachments":[{"url":"https://example.com/2.mp3","mime_type":"audio/mpeg"}]},
        {"id":"3","title":"Nothing"},
        {"id":"4","title":"Linked","url":"https://example.com/4"}]}
        """.utf8)
        let parsed = try FeedParser().parse(data: json)
        XCTAssertEqual(parsed.items.map(\.title), ["Audio only", "No id, audio only", "Linked"])
        guard parsed.items.count == 3 else { return }
        XCTAssertEqual(parsed.items[0].id, "1")
        XCTAssertEqual(parsed.items[0].url, "https://example.com/1.mp3")
        XCTAssertEqual(parsed.items[1].id, "https://example.com/2.mp3")
        XCTAssertEqual(parsed.items[2].id, "4")
    }

    private static func fixture(_ name: String) throws -> Data {
        try TestInputs.data(.contracts, "fixtures/feeds/\(name)")
    }
}
