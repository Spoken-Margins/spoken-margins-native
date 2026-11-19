import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4233, PR 1: a Margin moved from a live session onto an item can say it has no place, and that is kept in a record of
/// its own, never in the Margin's row. These run on a real SQLite file. The previous build's reading of the row is in
/// `SessionKitTests/MovedMarginOriginShippedReaderTests`.
final class MovedMarginOriginStoreTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appending(path: "library.sqlite").path }
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "moved-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func margin(_ id: String = "moved-1", session: String = "session-1", item: String = "item-1",
                        transcription: String = "transcribed", audioPath: String? = "SpokenMargins/interjections/live-1.m4a") -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: session, targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 0),
            audioPath: audioPath, audioStatus: "recorded", transcriptionStatus: transcription,
            transcript: "Words from the meeting.", cleanedTranscript: nil, displayText: "Words from the meeting.", status: "active",
            captureKind: .audio)
    }

    private func origin(_ margin: Interjection, placeKnown: Bool = false) -> MovedMarginOrigin {
        MovedMarginOrigin(
            marginId: margin.id, itemId: margin.itemId, sessionId: margin.sessionId,
            liveMarginId: "live-margin-1", fromLiveSessionId: "live-quick-1", fromLiveSessionTitle: "Quick session",
            sessionPlaceLabel: "about 1:23:10", markedAt: margin.createdAt, deviceMarkedAt: Date(timeIntervalSince1970: 1_779_999_990),
            movedAt: Date(timeIntervalSince1970: 1_780_100_000), placeKnown: placeKnown, placeSource: placeKnown ? "savedRun" : nil,
            filingNote: "Filed by time", clockNote: "Watch clock 2.0 s ahead, corrected", spokenOn: "watch", durationMs: 4_200)
    }

    private func saveMoved(_ margin: Interjection, placeKnown: Bool = false) throws -> MovedMarginOrigin {
        try store.saveInterjection(margin)
        let saved = origin(margin, placeKnown: placeKnown)
        try store.saveMovedMarginOrigin(saved)
        return saved
    }

    // MARK: 1. Save and reopen

    func testAnUnplacedMarginHasNoPlaceThroughEachRead() throws {
        let moved = margin()
        let saved = try saveMoved(moved)
        let plain = margin("made-on-item")
        try store.saveInterjection(plain)

        let reopened = try SQLiteSessionStore(path: path)
        let reads: [(String, Interjection?)] = [
            ("loadInterjection", try reopened.loadInterjection(id: moved.id, sessionId: moved.sessionId)),
            ("loadInterjections(sessionId:)", try reopened.loadInterjections(sessionId: moved.sessionId).first { $0.id == moved.id }),
            ("loadInterjections(itemId:)", try reopened.loadInterjections(itemId: moved.itemId).first { $0.id == moved.id }),
        ]
        for (name, read) in reads {
            let found = try XCTUnwrap(read, name)
            XCTAssertFalse(found.hasPlace, name)
            XCTAssertEqual(found.movedOrigin, saved, name)
        }
        let others = try reopened.loadInterjections(sessionId: moved.sessionId).filter { $0.id == plain.id }
        XCTAssertEqual(others.count, 1)
        XCTAssertTrue(others[0].hasPlace, "a Margin made on the item has a place")
        XCTAssertNil(others[0].movedOrigin)
    }

    func testAMovedMarginWithAKnownPlaceHasOne() throws {
        let moved = margin()
        _ = try saveMoved(moved, placeKnown: true)
        let found = try XCTUnwrap(try store.loadInterjection(id: moved.id, sessionId: moved.sessionId))
        XCTAssertTrue(found.hasPlace)
        XCTAssertEqual(found.movedOrigin?.placeSource, "savedRun")
    }

    func testTheSameMarginIdInTwoSessionsKeepsItsOwnOrigin() throws {
        let first = margin("same-id", session: "session-1")
        let second = margin("same-id", session: "session-2")
        try store.saveInterjection(first)
        try store.saveInterjection(second)
        try store.saveMovedMarginOrigin(origin(first))

        XCTAssertFalse(try XCTUnwrap(store.loadInterjection(id: "same-id", sessionId: "session-1")).hasPlace)
        XCTAssertTrue(try XCTUnwrap(store.loadInterjection(id: "same-id", sessionId: "session-2")).hasPlace)
    }

    // MARK: 2. The Margin's row is the row it always was

    /// Every stored property of a Margin has a key, and `movedOrigin` has none. A property added to `Interjection` without
    /// its key would be silently left out of the row; this fails until the key is added in `Interjection.CodingKeys`.
    func testEveryStoredPropertyOfAMarginHasAKeyAndTheOriginHasNone() throws {
        let stored = Set(Mirror(reflecting: margin()).children.compactMap(\.label)).subtracting(["_movedOrigin"])
        let expected: Set<String> = [
            "id", "itemId", "sessionId", "targetType", "targetId", "createdAt", "roughPercent", "anchor", "audioPath", "audioStatus",
            "transcriptionStatus", "transcript", "cleanedTranscript", "displayText", "status", "anchorContextStatus",
            "alignedTranscript", "podcastAnchorEvidence", "sourceExactEditionSHA256", "podcastAnchorEvidenceCaptureStatus",
            "podcastAnchorEvidenceFailureReason", "isStarredForSharing", "privateSharingNote", "captureKind", "replyTo", "sharedAs", "paperRole",
        ]
        XCTAssertEqual(stored, expected, "a stored property of Interjection has no key in the stored row (or one was removed)")

        var withEverythingSimple = margin()
        withEverythingSimple.isStarredForSharing = true
        withEverythingSimple.privateSharingNote = "for Sam"
        withEverythingSimple.sharedAs = [MarginPacketIdentity(packageDigest: "digest", packageScopedId: "moved-1")]
        try store.saveInterjection(withEverythingSimple)
        try store.saveMovedMarginOrigin(origin(withEverythingSimple))
        let json = try storedPayload(withEverythingSimple)
        let keys = Set(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]).keys)
        XCTAssertTrue(keys.isSubset(of: expected), "unexpected keys: \(keys.subtracting(expected))")
        XCTAssertTrue(keys.isSuperset(of: ["id", "itemId", "sessionId", "roughPercent", "anchor", "isStarredForSharing", "privateSharingNote", "sharedAs"]))
        XCTAssertFalse(json.contains("movedOrigin"))
        XCTAssertFalse(json.contains("fromLiveSessionTitle"), "the origin is a row of its own")
    }

    /// The encoder does not sort keys, so "the same row" is the same JSON, not the same text.
    func testSavingAMarginReadWithItsOriginWritesTheSameRow() throws {
        let moved = margin()
        try store.saveInterjection(moved)
        let before = try storedObject(moved)
        try store.saveMovedMarginOrigin(origin(moved))

        let read = try XCTUnwrap(try store.loadInterjection(id: moved.id, sessionId: moved.sessionId))
        XCTAssertNotNil(read.movedOrigin)
        try store.saveInterjection(read)

        XCTAssertEqual(try storedObject(moved), before, "the row is the one saved before the origin existed")
        XCTAssertEqual(read, moved, "a Margin is equal with or without its origin")
    }

    // MARK: 3. Settling keeps the origin

    func testSettlingAnOrphanedTranscriptionKeepsTheOrigin() throws {
        let moved = margin(transcription: "pending")
        let saved = try saveMoved(moved)

        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.settleOrphanedTranscriptions(), 1)

        let found = try XCTUnwrap(try reopened.loadInterjection(id: moved.id, sessionId: moved.sessionId))
        XCTAssertEqual(found.transcriptionStatus, "failed")
        XCTAssertEqual(found.movedOrigin, saved)
        XCTAssertFalse(found.hasPlace)
    }

    // MARK: 4. Quarantine

    func testAnOriginAnOlderBuildSetAsideIsBackWhenThisBuildOpensIt() throws {
        let moved = margin()
        let saved = try saveMoved(moved)
        let id = "\(moved.sessionId)::\(moved.id)"
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, 'set aside by an older build', '2026-02-03 04:05:06' FROM records WHERE kind = ? AND id = ?;
            """, bindings: [MovedMarginOrigin.recordKind, id], at: path)
        try StoreRawSQL.execute("DELETE FROM records WHERE kind = ? AND id = ?;", bindings: [MovedMarginOrigin.recordKind, id], at: path)
        XCTAssertEqual(try StoreRawSQL.ids(kind: MovedMarginOrigin.recordKind, at: path), [])

        let reopened = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try StoreRawSQL.ids(kind: MovedMarginOrigin.recordKind, at: path), [id])
        XCTAssertEqual(try reopened.loadInterjection(id: moved.id, sessionId: moved.sessionId)?.movedOrigin, saved)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
    }

    // MARK: 5. Purging the item

    func testPurgingTheItemRemovesTheOrigin() throws {
        let moved = margin()
        _ = try saveMoved(moved)
        let other = margin("elsewhere", session: "session-2", item: "item-2")
        _ = try saveMoved(other)

        try store.deleteItem(id: moved.itemId)

        XCTAssertEqual(try StoreRawSQL.ids(kind: MovedMarginOrigin.recordKind, at: path), ["session-2::elsewhere"])
        XCTAssertEqual(try store.loadMovedMarginOrigins().map(\.marginId), ["elsewhere"])
    }

    // MARK: 6. Deleting a moved Margin

    func testDeletingAMovedMarginRemovesBothRowsAndLeavesTheRecording() throws {
        let recording = directory.appending(path: "live-1.m4a")
        try Data("audio".utf8).write(to: recording)
        let moved = margin(audioPath: recording.path)
        _ = try saveMoved(moved)

        try store.deleteMovedMargin(id: moved.id, sessionId: moved.sessionId)

        XCTAssertNil(try store.loadInterjection(id: moved.id, sessionId: moved.sessionId))
        XCTAssertEqual(try StoreRawSQL.ids(kind: MovedMarginOrigin.recordKind, at: path), [])
        XCTAssertEqual(try StoreRawSQL.ids(kind: "interjection", at: path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path), "the live session may still name the recording")
    }

    func testDeletingAMovedMarginDoesNothingToAMarginWithNoOrigin() throws {
        let ordinary = margin("made-on-item")
        try store.saveInterjection(ordinary)
        try store.deleteMovedMargin(id: ordinary.id, sessionId: ordinary.sessionId)
        XCTAssertNotNil(try store.loadInterjection(id: ordinary.id, sessionId: ordinary.sessionId))
    }

    func testDeletingTheOriginAloneLeavesTheMargin() throws {
        let moved = margin()
        _ = try saveMoved(moved)
        try store.deleteMovedMarginOrigin(marginId: moved.id, sessionId: moved.sessionId)
        let found = try XCTUnwrap(try store.loadInterjection(id: moved.id, sessionId: moved.sessionId))
        XCTAssertNil(found.movedOrigin)
        try store.deleteMovedMarginOrigin(marginId: "no-such", sessionId: "session-1") // nothing to remove: no error
    }

    // MARK: Recovery and Undo

    func testLoadingOriginsForRecoveryReturnsOnlyThoseWhoseMarginIsActive() throws {
        let kept = margin("kept")
        _ = try saveMoved(kept)
        var removed = margin("removed")
        _ = try saveMoved(removed)
        removed.status = "deleted"
        try store.saveInterjection(removed) // the listener deleted it: status only, the origin stays for Undo
        try store.saveMovedMarginOrigin(origin(margin("orphan"))) // an origin with no Margin row at all

        XCTAssertEqual(try store.loadMovedMarginOrigins().map(\.marginId), ["kept"])
        removed.status = "active"
        try store.saveInterjection(removed) // Undo
        XCTAssertEqual(Set(try store.loadMovedMarginOrigins().map(\.marginId)), ["kept", "removed"])
        XCTAssertEqual(try store.loadInterjection(id: "removed", sessionId: "session-1")?.movedOrigin?.fromLiveSessionTitle, "Quick session")
    }

    func testADeletedMarginKeepsItsOriginForUndo() throws {
        var moved = margin()
        let saved = try saveMoved(moved)
        moved.status = "deleted"
        try store.saveInterjection(moved)
        XCTAssertEqual(try store.loadInterjection(id: moved.id, sessionId: moved.sessionId)?.movedOrigin, saved)
    }

    func testAStoreThatDoesNotAdoptTheProtocolHoldsNoOriginsAndRefusesToSaveOne() throws {
        struct Bare: MovedMarginOriginRepository {}
        let bare = Bare()
        XCTAssertEqual(try bare.loadMovedMarginOrigins(), [])
        XCTAssertThrowsError(try bare.saveMovedMarginOrigin(origin(margin())))
        XCTAssertThrowsError(try bare.deleteMovedMargin(id: "a", sessionId: "b"))
        XCTAssertNoThrow(try bare.deleteMovedMarginOrigin(marginId: "a", sessionId: "b"))
    }

    private func storedObject(_ margin: Interjection) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try storedPayload(margin).utf8)) as? NSDictionary)
    }

    private func storedPayload(_ margin: Interjection) throws -> String {
        let rows = try StoreRawSQL.rows("SELECT payload FROM records WHERE kind = 'interjection' AND id = ?;",
                                        bindings: ["\(margin.sessionId)::\(margin.id)"], at: path)
        return try XCTUnwrap(try XCTUnwrap(rows.first).first ?? nil)
    }
}
