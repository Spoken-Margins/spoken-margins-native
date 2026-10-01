import Foundation
import XCTest
@testable import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// #177: a podcast added from a feed keeps its episode GUID, show title and publish date, so a
/// shared Margin can be matched to the recipient's copy by GUID.
final class EpisodeGUIDStorageTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: ["sync": ["canonical_persistence"]]
    )

    private func feed(guid: String?) -> String {
        """
        <rss version="2.0"><channel><title>Example Show</title><item><title>Episode One</title>
        \(guid.map { "<guid isPermaLink=\"false\">\($0)</guid>" } ?? "")
        <pubDate>Tue, 29 Sep 2026 10:00:00 GMT</pubDate>
        <enclosure url="https://media.example.com/one.mp3?token=abcdefabcdefabcdefabcdefabcdefabcdef" type="audio/mpeg" />
        </item></channel></rss>
        """
    }

    private func importFeed(_ xml: String, into engine: SessionEngine) throws -> String {
        let request = LinkResolutionRequest(
            id: "add-episode", inputURL: "https://example.com/feed.xml", sourceSurface: "paste", createdAt: Date()
        )
        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(xml.utf8) }).resolve(request)
        XCTAssertEqual(result.status, .playable)
        return try XCTUnwrap(try engine.importResolvedSourceLink(request, result: result).itemId)
    }

    private func temporaryStorePath() throws -> (folder: URL, path: String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "episode-guid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appending(path: "library.sqlite").path)
    }

    func testAnEpisodeAddedFromItsFeedStoresItsGUIDShowAndDate() throws {
        let (folder, path) = try temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let itemId = try importFeed(
            feed(guid: "show-episode-0001"),
            into: SessionEngine(profile: profile, repository: try SQLiteSessionStore(path: path))
        )

        let stored = try SQLiteSessionStore(path: path).loadItem(id: itemId)
        XCTAssertEqual(stored.episodeGUID, "show-episode-0001")
        XCTAssertEqual(stored.showTitle, "Example Show")
        XCTAssertEqual(stored.publishedAt, "Tue, 29 Sep 2026 10:00:00 GMT")
    }

    func testReAddingAnEpisodeFillsAMissingGUIDAndKeepsTheRest() throws {
        let (folder, path) = try temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = SessionEngine(profile: profile, repository: try SQLiteSessionStore(path: path))
        let itemId = try importFeed(feed(guid: nil), into: engine)
        let before = try SQLiteSessionStore(path: path).loadItem(id: itemId)
        XCTAssertNil(before.episodeGUID)

        XCTAssertEqual(try importFeed(feed(guid: "show-episode-0001"), into: engine), itemId)

        let after = try SQLiteSessionStore(path: path).loadItem(id: itemId)
        XCTAssertEqual(after.episodeGUID, "show-episode-0001")
        XCTAssertEqual(after.createdAt, before.createdAt)
        XCTAssertEqual(after.media, before.media)
        XCTAssertEqual(after.title, before.title)
    }

    func testAStoredGUIDIsNotReplacedOnReAdd() throws {
        let (folder, path) = try temporaryStorePath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = SessionEngine(profile: profile, repository: try SQLiteSessionStore(path: path))
        let itemId = try importFeed(feed(guid: "first-guid"), into: engine)
        _ = try importFeed(feed(guid: "changed-guid"), into: engine)
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadItem(id: itemId).episodeGUID, "first-guid")
    }

    /// Records saved before #177 have none of the new keys and still decode.
    func testAnItemRecordWithoutTheNewFieldsStillDecodes() throws {
        let legacy = Data(#"{"id":"old","title":"Old","mediaType":"transcript_backed_media","status":"ready"}"#.utf8)
        let item = try JSONDecoder().decode(Item.self, from: legacy)
        XCTAssertNil(item.episodeGUID)
        XCTAssertNil(item.showTitle)
        XCTAssertNil(item.publishedAt)
    }
}
