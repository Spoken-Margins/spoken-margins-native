import Foundation
import XCTest
import SessionKit
import ShippedSessionKit

/// Build 29 must still read an item saved with the #1322 `descriptionText`. The store writes an item as JSON in the
/// `records` payload; this decodes that payload with Build 29's frozen model, which ignores the key.
final class ItemDescriptionBuild29Tests: XCTestCase {
    func testItemWithADescriptionDecodesWithBuild29sModelAndTheFieldIsIgnored() throws {
        var item = SessionKit.Item(id: "episode", title: "Episode One", mediaType: "transcript_backed_media",
                                   text: nil, externalReference: nil, status: "ready")
        item.episodeGUID = "guid-1"
        item.showTitle = "Example Show"
        item.publishedAt = "2026-09-29T10:00:00Z"
        item.descriptionText = "Notes for the episode."
        let payload = try JSONEncoder().encode(item)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("\"descriptionText\""))

        let shipped = try JSONDecoder().decode(ShippedSessionKit.Item.self, from: payload)
        XCTAssertEqual(shipped.id, "episode")
        XCTAssertEqual(shipped.title, "Episode One")
        XCTAssertEqual(shipped.mediaType, "transcript_backed_media")
        XCTAssertEqual(shipped.status, "ready")
    }
}
