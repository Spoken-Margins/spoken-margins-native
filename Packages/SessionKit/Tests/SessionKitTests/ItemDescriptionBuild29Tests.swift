import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
import ShippedSessionKit

/// Build 29 must still read an item saved with the #1322 `descriptionText`. The item is saved through the store and
/// the `records` payload it wrote is decoded with Build 29's frozen model, which ignores the key (#4309).
final class ItemDescriptionBuild29Tests: XCTestCase {
    func testItemWithADescriptionDecodesWithBuild29sModelAndTheFieldIsIgnored() throws {
        let path = try StoredRecordFile.temporaryPath(for: self)
        var item = SessionKit.Item(id: "episode", title: "Episode One", mediaType: "transcript_backed_media",
                                   text: nil, externalReference: nil, status: "ready")
        item.episodeGUID = "guid-1"
        item.showTitle = "Example Show"
        item.publishedAt = "2026-09-29T10:00:00Z"
        item.descriptionText = "Notes for the episode."
        try SQLiteSessionStore(path: path).saveItem(item)
        let payload = try StoredRecordFile.payload(path: path, kind: "item", id: "episode")
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("\"descriptionText\""))

        let shipped = try StoredRecordFile.decodeInShippedBuild(ShippedSessionKit.Item.self, from: payload)
        XCTAssertEqual(shipped.id, "episode")
        XCTAssertEqual(shipped.title, "Episode One")
        XCTAssertEqual(shipped.mediaType, "transcript_backed_media")
        XCTAssertEqual(shipped.status, "ready")
    }
}
