import Foundation
import SessionKit
@testable import SessionKitSharing
import SessionKitTestInputs
import XCTest

/// #4689: a friend who opens Ana's link on the web without following the show has the episode filed under a holder the
/// web titles "Shared by Ana". Earlier web builds wrote that holder's title as the reply packet's show, and Ana's iPhone,
/// seeing another show beside the same GUID, matched none of her items and imported a second copy, so the replies sat
/// apart from the Margins they answered. Both web files (`node Web/src/packet/fixtures.ts`) now land on her own copy: the
/// new one names the real show, and the one earlier builds sent is read as naming none.
final class WebSharedHolderReplyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebSharedHolderReplyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func anasCopy(id: String = "anas-copy", showTitle: String = "Example Show") -> Item {
        let audio = "https://example.com/podcast/episode-1.mp3"
        var item = Item(
            id: id, title: "Episode 1 (example episode)", mediaType: "transcript_backed_media", text: nil,
            externalReference: audio, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: audio, durationMs: 1_800_000)
        )
        item.episodeGUID = "example-episode-guid-1"
        item.showTitle = showTitle
        return item
    }

    private func packetItem(_ name: String) throws -> SharedItemIdentity {
        let url = try TestInputs.url(.contracts, "fixtures/web-packets/\(name).spokenmargins")
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent(name)).manifest.item
    }

    func testTheNewWebReplyNamesTheShowAndLandsOnAnasCopy() throws {
        let item = try packetItem("web-reply-from-shared")
        XCTAssertEqual(item.showTitle, "Example Show")
        XCTAssertEqual(item.episodeGUID, "example-episode-guid-1")
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: item, among: [anasCopy()]), "anas-copy")
        // A real show title still rules out another show's episode that reuses the GUID (#177).
        XCTAssertNil(SharedPacketItemMatcher.matchingItemId(for: item, among: [anasCopy(id: "other", showTitle: "A Different Show")]))
    }

    func testAReplyEarlierWebBuildsSentWithTheHolderTitleLandsOnAnasCopy() throws {
        let item = try packetItem("web-reply-holder-titled")
        XCTAssertEqual(item.showTitle, "Shared by Ana")
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: item, among: [anasCopy()]), "anas-copy")
        // A copy imported from such a file earlier kept the holder title; a later file from the real show still finds it.
        let fromShow = try packetItem("web-reply-from-shared")
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: fromShow, among: [anasCopy(showTitle: "Shared by Ana")]), "anas-copy")
    }

    /// The web's holder titles, and show titles that only look like one.
    func testOnlyTheWebsHolderTitlesNameNoShow() {
        for title in ["Shared by Ana", "shared by ana", "  Shared  by   Ana ", "Shared with you", "SHARED WITH YOU", "Shared by Zoë", "<b>Shared by Ana</b>"] {
            XCTAssertTrue(ImportedItemResolver.guidShowsAreCompatible(title, "Example Show"), title)
            XCTAssertTrue(ImportedItemResolver.guidShowsAreCompatible("Example Show", title), title)
        }
        for title in ["Shared by", "Shared by ", "Shared Brains", "The Shared by Show", "Shared withyou", "A Different Show"] {
            XCTAssertFalse(ImportedItemResolver.guidShowsAreCompatible(title, "Example Show"), title)
        }
        XCTAssertTrue(ImportedItemResolver.guidShowsAreCompatible(nil, "Example Show"))
        XCTAssertTrue(ImportedItemResolver.guidShowsAreCompatible(" example show ", "Example Show"))
    }
}
