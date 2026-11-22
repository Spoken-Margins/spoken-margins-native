import Foundation
import SessionKit
import SessionKitPersistence
import ShippedPacketReader
import ShippedSessionKit
import XCTest

/// The database the last shipped build opens (#4178): an item marked added again still decodes there, and the old
/// reader ignores the new field. The row is the one `SQLiteSessionStore` wrote, read from the file (#4309).
final class AddedAgainShippedReaderTests: XCTestCase {
    func testTheShippedBuildStillReadsAnItemAddedAgain() throws {
        let path = try StoredRecordFile.temporaryPath(for: self)
        var item = SessionKit.Item(id: "item-browser-essay", title: "Essay", mediaType: "text", text: "Words.",
                                   externalReference: "https://example.com/essay", status: "ready",
                                   externalReferenceType: "url", createdAt: Date(timeIntervalSince1970: 1_777_000_000))
        item.addedAgainAt = Date(timeIntervalSince1970: 1_778_000_000)
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(item)

        let stored = try StoredRecordFile.payload(path: path, kind: "item", id: item.id)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("addedAgainAt"),
                      "the field the shipped build has never seen is in the stored row")
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "item", payload: stored), item.id)
        let shipped = try StoredRecordFile.decodeInShippedBuild(ShippedSessionKit.Item.self, from: stored)
        XCTAssertEqual(shipped.text, "Words.")
        XCTAssertEqual(shipped.createdAt, item.createdAt)
        XCTAssertEqual(try store.loadItem(id: item.id).addedAgainAt, item.addedAgainAt)
    }
}
