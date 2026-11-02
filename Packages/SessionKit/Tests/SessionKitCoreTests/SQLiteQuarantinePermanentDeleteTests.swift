import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1466: "Permanently deleted" removed an item's live records and left the unreadable ones in
/// `quarantined_records` (an older build set them aside because it couldn't decode them). They kept
/// the item's text and voice recordings on disk, and `restoreQuarantinedRecords()` would put them back
/// as orphans on a build that could read them. Permanent delete now takes the item's quarantined rows
/// with it, and says which recordings they name; rows of other items stay quarantined untouched.
///
/// Real SQLite on a real file. The older build is played by raw inserts into `quarantined_records`:
/// the current store decodes everything this build knows, so it cannot quarantine them itself.
final class SQLiteQuarantinePermanentDeleteTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appending(path: "library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ id: String) -> String {
        #"{"id":"\#(id)","title":"Article \#(id)","mediaType":"text","text":"Body of \#(id).","status":"ready"}"#
    }

    private func session(_ id: String, item: String) -> String {
        #"{"id":"\#(id)","itemId":"\#(item)","status":"in_progress","phase":"item_playback","currentTargetType":"item_text_tts","currentTargetId":"\#(item)","playbackRate":1,"completionPercent":10,"position":{"charOffset":3}}"#
    }

    /// A voice Margin whose `captureKind` this build can't read until `makeDecodable()`.
    private func margin(_ id: String, session: String, item: String, audio: String?) -> String {
        let audioPath = audio.map { #""audioPath":"\#($0)","# } ?? ""
        return #"{"id":"\#(id)","sessionId":"\#(session)","itemId":"\#(item)","targetType":"item","targetId":"\#(item)","status":"active","audioStatus":"none",\#(audioPath)"transcriptionStatus":"transcribed","transcript":"A note.","displayText":"A note.","roughPercent":10,"createdAt":"2026-01-02T03:04:05Z","captureKind":"dictated-in-a-future-build","anchor":{"anchorType":"text","startChar":1,"endChar":4,"anchorBefore":"","anchorAfter":"","playbackRateObserved":1}}"#
    }

    private func turn(_ id: String, session: String) -> String {
        #"{"id":"\#(id)","sessionId":"\#(session)","role":"from-a-future-build","text":"A reply."}"#
    }

    private func layer(_ id: String, item: String) -> String {
        #"{"id":"\#(id)","itemId":"\#(item)","packageDigest":"digest-\#(id)","from-a-future-build":true}"#
    }

    private func importedMargin(_ id: String, layer: String) -> String {
        #"{"id":"\#(id)","layerId":"\#(layer)","from-a-future-build":true}"#
    }

    private func insert(kind: String, id: String, sessionId: String?, itemId: String?, payload: String) throws {
        try StoreRawSQL.execute("INSERT INTO records(kind,id,session_id,item_id,payload) VALUES(?,?,?,?,?);",
                                bindings: [kind, id, sessionId, itemId, payload], at: path)
    }

    private func quarantine(_ kind: String, _ id: String, _ payload: String) throws {
        try StoreRawSQL.execute(
            "INSERT INTO quarantined_records(kind,id,payload,decode_error,quarantined_at) VALUES(?,?,?,?,'2026-02-03 04:05:06');",
            bindings: [kind, id, payload, "dataCorrupted: unreadable here"], at: path)
    }

    private func quarantined() throws -> [[String?]] {
        try StoreRawSQL.rows("SELECT kind, id, payload FROM quarantined_records ORDER BY kind, id;", at: path)
    }

    private func quarantinedKeys() throws -> [String] {
        try quarantined().map { "\($0[0] ?? "")/\($0[1] ?? "")" }
    }

    /// item-1 (the one that gets deleted) and item-2 (unrelated), each with unreadable rows set aside.
    private func seed() throws {
        _ = try SQLiteSessionStore(path: path)
        for id in ["item-1", "item-2"] {
            try insert(kind: "item", id: id, sessionId: nil, itemId: id, payload: item(id))
        }
        try insert(kind: "session", id: "session-1", sessionId: "session-1", itemId: "item-1", payload: session("session-1", item: "item-1"))
        try insert(kind: "session", id: "session-2", sessionId: "session-2", itemId: "item-2", payload: session("session-2", item: "item-2"))
        // item-1: a Margin with a recording, a turn of its live session, a quarantined session with its own
        // Margin and turn, and an imported layer with its Margin.
        try quarantine("interjection", "session-1::note-1", margin("note-1", session: "session-1", item: "item-1", audio: "SpokenMargins/note-1.m4a"))
        try quarantine("turn", "session-1::turn-1", turn("turn-1", session: "session-1"))
        try quarantine("session", "session-q", session("session-q", item: "item-1").replacingOccurrences(of: #""playbackRate":1"#, with: #""playbackRate":"from-a-future-build""#))
        try quarantine("interjection", "session-q::note-q", margin("note-q", session: "session-q", item: "item-1", audio: "SpokenMargins/note-q.m4a"))
        try quarantine("turn", "session-q::turn-q", turn("turn-q", session: "session-q"))
        try quarantine("imported_commentary_layer", "layer-1", layer("layer-1", item: "item-1"))
        try quarantine("imported_commentary_interjection", "layer-1::imported-1", importedMargin("imported-1", layer: "layer-1"))
        // item-2 and a kind with no item at all: not the deleted item's.
        try quarantine("interjection", "session-2::note-2", margin("note-2", session: "session-2", item: "item-2", audio: "SpokenMargins/note-2.m4a"))
        try quarantine("turn", "session-2::turn-2", turn("turn-2", session: "session-2"))
        try quarantine("imported_commentary_layer", "layer-2", layer("layer-2", item: "item-2"))
        try quarantine("imported_commentary_interjection", "layer-2::imported-2", importedMargin("imported-2", layer: "layer-2"))
        try quarantine("watch_capture_handoff", "handoff-1", #"{"id":"handoff-1","from-a-future-build":true}"#)
    }

    private let deletedItemKeys = [
        "imported_commentary_interjection/layer-1::imported-1", "imported_commentary_layer/layer-1",
        "interjection/session-1::note-1", "interjection/session-q::note-q", "session/session-q",
        "turn/session-1::turn-1", "turn/session-q::turn-q"
    ]

    func testPermanentDeleteTakesTheItemsQuarantinedRowsAndLeavesEveryOtherRowAlone() throws {
        try seed()
        let others = try quarantined().filter { !deletedItemKeys.contains("\($0[0] ?? "")/\($0[1] ?? "")") }
        XCTAssertEqual(others.count, 5)
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try store.quarantinedRecordCount(), 12, "nothing here is readable yet, so opening restores none")

        try store.deleteItem(id: "item-1")

        XCTAssertEqual(try quarantined(), others, "the other rows stay, byte for byte")
        XCTAssertNil(try? store.loadItem(id: "item-1"))
        XCTAssertEqual(try store.loadItem(id: "item-2").id, "item-2")
    }

    func testTheQuarantinedMarginRecordingsAreNamedSoTheFilesCanGo() throws {
        try seed()
        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try store.quarantinedMarginAudioPaths(itemId: "item-1").sorted(),
                       ["SpokenMargins/note-1.m4a", "SpokenMargins/note-q.m4a"])
        XCTAssertEqual(try store.quarantinedMarginAudioPaths(itemId: "item-2"), ["SpokenMargins/note-2.m4a"])
        XCTAssertEqual(try store.quarantinedMarginAudioPaths(itemId: "item-without-any"), [])
        try store.deleteItem(id: "item-1")
        XCTAssertEqual(try store.quarantinedMarginAudioPaths(itemId: "item-1"), [], "gone with the rows")
        XCTAssertEqual(try store.allMarginAudioPaths(), ["SpokenMargins/note-2.m4a"],
                       "so the recording cleanup no longer sees them as surviving Margins")
    }

    func testNothingComesBackWhenALaterBuildCanReadTheSetAsidePayloads() throws {
        try seed()
        _ = try SQLiteSessionStore(path: path)  // an open that restores nothing
        try SQLiteSessionStore(path: path).deleteItem(id: "item-1")

        // A newer decoder: the rows still set aside become readable.
        try StoreRawSQL.execute("""
            UPDATE quarantined_records SET payload = replace(payload, 'dictated-in-a-future-build', 'written');
            """, at: path)
        let reopened = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try reopened.loadInterjections(itemId: "item-1"), [])
        XCTAssertEqual(try StoreRawSQL.ids(kind: "interjection", at: path), ["session-2::note-2"],
                       "item-2's Margin, readable now, is restored; item-1's has no row to come back from")
        XCTAssertEqual(try StoreRawSQL.rows("SELECT id FROM records WHERE item_id = 'item-1';", at: path), [])
        XCTAssertFalse(try quarantinedKeys().contains { $0.contains("item-1") || $0.contains("note-1") || $0.contains("-q") })
    }

    func testBulkEmptyingRecentlyDeletedTakesEveryItemsQuarantinedRows() throws {
        try seed()
        let store = try SQLiteSessionStore(path: path)

        try store.deleteItems(ids: ["item-1", "item-2"])

        XCTAssertEqual(try quarantinedKeys(), ["watch_capture_handoff/handoff-1"])
    }

    func testARowThatIsNotJSONStaysAndDoesNotStopTheDelete() throws {
        try seed()
        try quarantine("interjection", "session-1::broken", "{not json at all")
        let store = try SQLiteSessionStore(path: path)

        try store.deleteItem(id: "item-1")

        XCTAssertTrue(try quarantinedKeys().contains("interjection/session-1::broken"),
                      "a payload that can't be read can't be tied to the item, so it is left set aside")
        XCTAssertFalse(try quarantinedKeys().contains("interjection/session-1::note-1"))
    }

    func testTheQuarantineSurvivesWhileTheItemIsOnlyInRecentlyDeleted() throws {
        try seed()
        let store = try SQLiteSessionStore(path: path)
        var trashed = try store.loadItem(id: "item-1")
        trashed.deletedAt = Date()
        try store.saveItem(trashed)

        XCTAssertEqual(try store.quarantinedRecordCount(), 12, "undo must still be able to bring everything back")
    }

    func testTheRecordingsOfQuarantinedMarginsAreRemovedAsFilesUnlessASurvivingMarginNamesThem() throws {
        let root = directory.appending(path: "SpokenMargins", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["note-1.m4a", "note-q.m4a", "shared.m4a"] {
            try Data("voice".utf8).write(to: root.appending(path: name))
        }
        let outside = directory.appending(path: "elsewhere.m4a")
        try Data("not ours".utf8).write(to: outside)
        func resolve(_ path: String) -> URL? { directory.appending(path: path) }

        let removed = MarginRecordingCleanup.removeFiles(
            deletedAudioPaths: ["SpokenMargins/note-1.m4a", "SpokenMargins/note-q.m4a", "SpokenMargins/shared.m4a", "elsewhere.m4a"],
            survivingAudioPaths: ["SpokenMargins/shared.m4a"], within: root, resolve: resolve)

        XCTAssertEqual(removed.map(\.lastPathComponent).sorted(), ["note-1.m4a", "note-q.m4a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "shared.m4a").path), "a surviving Margin still uses it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "only files under the recordings folder are ever removed")
    }

    func testAQuarantinedExtractedDocumentGoesButAnUploadRecordAndALookalikeItemStay() throws {
        try seed()
        try quarantine("structured_document", "item-1#v2", #"{"text":"EXTRACTED PDF TEXT","from-a-future-build":true}"#)
        try quarantine("structured_document", "item-10#v2", #"{"text":"another item's","from-a-future-build":true}"#)
        try quarantine("source_elements", "item-1#elements", #"{"from-a-future-build":true,"elements":[{"url":"https://example.com/a"}]}"#)
        try quarantine("source_elements", "item-10#elements", #"{"from-a-future-build":true}"#)
        try quarantine("community_map_upload", "episode-key", #"{"id":"episode-key","itemId":"item-1","from-a-future-build":true}"#)
        try quarantine("interjection", "session-10::note", margin("note", session: "session-10", item: "item-10", audio: "SpokenMargins/note-10.m4a"))
        let store = try SQLiteSessionStore(path: path)

        try store.deleteItem(id: "item-1")

        let kept = try quarantinedKeys()
        XCTAssertFalse(kept.contains("structured_document/item-1#v2"), "the extracted text is the item's")
        XCTAssertTrue(kept.contains("structured_document/item-10#v2"), "item-10 is not item-1")
        XCTAssertFalse(kept.contains("source_elements/item-1#elements"), "a set-aside picture, link and embed list goes with its item (#2032)")
        XCTAssertTrue(kept.contains("source_elements/item-10#elements"), "item-10 is not item-1")
        XCTAssertTrue(kept.contains("interjection/session-10::note"))
        XCTAssertTrue(kept.contains("community_map_upload/episode-key"),
                      "a live upload record deliberately outlives its item, so a quarantined one does too")
    }

    /// #1499: the audit of #1481 found three kinds whose live rows are saved under the item but whose set-aside
    /// rows stayed behind after a permanent delete. `publisher_audio` is keyed by the item id; the watch
    /// kinds name the item in their payload, and a sync event's payload also names a recording.
    func testPublisherAudioAndWatchRowsOfTheItemGoButAnotherItemsAndALookalikeStay() throws {
        try seed()
        func publisherAudio(_ item: String) -> String {
            #"{"itemId":"\#(item)","audioURL":"https://example.com/\#(item).mp3","detectedFrom":"feed_enclosure","from-a-future-build":true}"#
        }
        func syncEvent(_ id: String, item: String) -> String {
            #"{"id":"\#(id)","itemId":"\#(item)","sessionId":"session-\#(item)","audioFileName":"\#(id).m4a","from-a-future-build":true}"#
        }
        func packageRequest(_ id: String, item: String) -> String {
            #"{"id":"\#(id)","itemId":"\#(item)","requestType":"prerender_requested","from-a-future-build":true}"#
        }
        for item in ["item-1", "item-2", "item-10"] {
            try quarantine("publisher_audio", item, publisherAudio(item))
            try quarantine("watch_sync_event", "sync-\(item)", syncEvent("sync-\(item)", item: item))
            try quarantine("watch_package_request", "request-\(item)", packageRequest("request-\(item)", item: item))
        }
        let keptBefore = try quarantined().filter { row in
            let id = row[1] ?? ""
            return !id.hasSuffix("item-1") && !deletedItemKeys.contains("\(row[0] ?? "")/\(id)")
        }
        XCTAssertEqual(keptBefore.count, 5 + 6, "the seeded rows of other items plus item-2's and item-10's new ones")
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try store.quarantinedRecordCount(), 12 + 9)

        try store.deleteItem(id: "item-1")
        let reopened = try SQLiteSessionStore(path: path)

        let kept = try quarantinedKeys()
        for key in ["publisher_audio/item-1", "watch_sync_event/sync-item-1", "watch_package_request/request-item-1"] {
            XCTAssertFalse(kept.contains(key), "\(key) belongs to the deleted item")
        }
        XCTAssertEqual(try quarantined().filter { row in keptBefore.contains(row) }, keptBefore,
                       "every other row stays, byte for byte")
        for key in ["publisher_audio/item-10", "watch_sync_event/sync-item-10", "watch_package_request/request-item-10",
                    "publisher_audio/item-2", "watch_sync_event/sync-item-2", "watch_package_request/request-item-2"] {
            XCTAssertTrue(kept.contains(key), "\(key) is not item-1's")
        }
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 21 - 3 - deletedItemKeys.count, "also after the file is opened again")
    }

    func testTheLiveTurnsOfAQuarantinedSessionGoWithTheItem() throws {
        try seed()
        _ = try SQLiteSessionStore(path: path)
        try insert(kind: "turn", id: "session-q::live-turn", sessionId: "session-q", itemId: nil,
                   payload: #"{"id":"live-turn","sessionId":"session-q","role":"user","text":"Hello."}"#)

        try SQLiteSessionStore(path: path).deleteItem(id: "item-1")

        XCTAssertEqual(try StoreRawSQL.ids(kind: "turn", at: path), [], "the turn's session was set aside, not live")
    }

    func testAMarginRowWithAnUnreadableRecordingPathDoesNotMakeThePermanentDeleteImpossible() throws {
        try seed()
        try quarantine("interjection", "session-1::odd", #"{"id":"odd","sessionId":"session-1","itemId":"item-1","audioPath":5}"#)
        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try store.quarantinedMarginAudioPaths(itemId: "item-1").sorted(),
                       ["SpokenMargins/note-1.m4a", "SpokenMargins/note-q.m4a"], "the readable ones are still named")
        try store.deleteItem(id: "item-1")
        XCTAssertFalse(try quarantinedKeys().contains("interjection/session-1::odd"))
    }

    func testNothingSetAsideMeansNothingToScan() throws {
        _ = try SQLiteSessionStore(path: path)
        try insert(kind: "item", id: "item-1", sessionId: nil, itemId: "item-1", payload: item("item-1"))
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try store.quarantinedMarginAudioPaths(itemId: "item-1"), [])
        try store.deleteItem(id: "item-1")
        XCTAssertNil(try? store.loadItem(id: "item-1"))
    }
}
