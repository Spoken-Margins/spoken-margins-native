import Foundation
import SessionKit
import SessionKitPersistence
import ShippedPacketReader
import ShippedSessionKit
import XCTest

/// The database the last shipped build opens (#4233, PR 1): a Margin moved from a live session is the same row an older
/// build reads, and the record that says it has no place is a kind that build never selects. The rows are the ones
/// `SQLiteSessionStore` wrote, read from the file (#4309).
final class MovedMarginOriginShippedReaderTests: XCTestCase {
    func testTheShippedBuildStillReadsAMovedMarginAndNeverSelectsItsOrigin() throws {
        let path = try StoredRecordFile.temporaryPath(for: self)
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        let margin = SessionKit.Interjection(
            id: "moved-1", itemId: "item-1", sessionId: "session-1", targetType: .item, targetId: "item-1",
            createdAt: createdAt, roughPercent: 0,
            anchor: SessionKit.Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 0),
            audioPath: "SpokenMargins/interjections/live-1.m4a", audioStatus: "recorded", transcriptionStatus: "transcribed",
            transcript: "Words.", cleanedTranscript: nil, displayText: "Words.", status: "active", captureKind: .audio)
        let store = try SQLiteSessionStore(path: path)
        try store.saveInterjection(margin)
        try store.saveMovedMarginOrigin(MovedMarginOrigin(
            marginId: margin.id, itemId: margin.itemId, sessionId: margin.sessionId,
            liveMarginId: "live-margin-1", fromLiveSessionId: "live-quick-1", fromLiveSessionTitle: "Quick session",
            markedAt: createdAt, movedAt: createdAt.addingTimeInterval(60), placeKnown: false))

        let stored = try StoredRecordFile.payload(path: path, kind: "interjection", id: "session-1::moved-1")
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("movedOrigin"), "the Margin's row has no field for it")
        let shipped = try StoredRecordFile.decodeInShippedBuild(ShippedSessionKit.Interjection.self, from: stored)
        XCTAssertEqual(shipped.id, margin.id)
        XCTAssertEqual(shipped.transcript, "Words.")
        XCTAssertEqual(shipped.audioPath, margin.audioPath)
        XCTAssertEqual(shipped.roughPercent, 0, "an older build shows it at 0%, the cost the Design accepted")

        // The origin is its own row, in a kind the shipped build's reads do not select by name.
        let origin = try StoredRecordFile.payload(path: path, kind: MovedMarginOrigin.recordKind, id: "session-1::moved-1")
        XCTAssertTrue(String(decoding: origin, as: UTF8.self).contains("placeKnown"))
        XCTAssertEqual(try store.loadInterjection(id: margin.id, sessionId: margin.sessionId)?.hasPlace, false)
    }
}
