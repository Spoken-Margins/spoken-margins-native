import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #3410: the folder names permanent delete reads for a friend's item come out of SQLite (`json_tree`), not from
/// whole payloads in Swift. Safety rests on one property: for every folder, the read names it exactly when the
/// sweep's own check (`importedCommentaryRecordsMentioning`, which decides what stays) says an imported row uses
/// it. This runs both on the same real SQLite rows and fails if they disagree.
final class FriendPacketFolderCandidatesTests: XCTestCase {
    private struct Row {
        var table = "records"
        var kind = "imported_commentary_interjection"
        var id = UUID().uuidString
        var itemId: String? = "a"
        var payload: String
    }

    private struct Fixture {
        var name: String
        /// The folder names on disk; every one is checked against both reads.
        var folders: [String]
        var rows: [Row]
        /// For a shape where the read finds more than the sweep (never fewer).
        var mayExceedSweep = false
    }

    private let f1 = "AAAAAAAA-1111-4111-8111-111111111111"
    private let f2 = "BBBBBBBB-2222-4222-8222-222222222222"
    private let f3 = "CCCCCCCC-3333-4333-8333-333333333333"

    private func voice(_ f: String, file: String = "voice.m4a") -> String {
        "/var/mobile/App/SpokenMargins/IncomingPackages/\(f)/assets/\(file)"
    }

    private func fixtures() -> [Fixture] {
        let lower = f1.lowercased()
        let nearMiss = String(f1.dropLast()) + "2"
        let longText = String(repeating: "word ", count: 200_000)
        let nested = String(repeating: #"{"n":"#, count: 40) + "\"\(voice(f1))\"" + String(repeating: "}", count: 40)
        return [
            Fixture(name: "audioPath absolute", folders: [f1, f2],
                    rows: [Row(payload: #"{"id":"m1","layerId":"l1","audioPath":"\#(voice(f1))"}"#)]),
            Fixture(name: "audioPath relative", folders: [f1, f2],
                    rows: [Row(payload: #"{"id":"m1","audioPath":"IncomingPackages/\#(f1)/assets/voice.m4a"}"#)]),
            Fixture(name: "escaped slashes in JSON", folders: [f1, f2],
                    rows: [Row(payload: #"{"audioPath":"\/var\/mobile\/IncomingPackages\/\#(f1)\/assets\/voice.m4a"}"#)]),
            Fixture(name: "file URL with percent-encoding", folders: [f1, f2],
                    rows: [Row(payload: #"{"audioPath":"file:///var/My%20Library/IncomingPackages/\#(f1)/assets/my%20voice.m4a"}"#)]),
            Fixture(name: "several recordings, several folders", folders: [f1, f2, f3],
                    rows: [Row(payload: #"{"audioPath":"\#(voice(f1))"}"#), Row(payload: #"{"audioPath":"\#(voice(f2))"}"#)]),
            Fixture(name: "podcast evidence with many local paths", folders: [f1, f2, f3],
                    rows: [Row(payload: #"{"audioPath":null,"podcastAnchorEvidence":[{"id":"e1","localPath":"\#(voice(f1, file: "e1.m4a"))","anchorOffsetMs":0},{"id":"e2","localPath":"\#(voice(f2, file: "e2.m4a"))","anchorOffsetMs":-500}]}"#)]),
            Fixture(name: "layer with episode map evidence paths (values and keys)", folders: [f1, f2, f3],
                    rows: [Row(kind: "imported_commentary_layer", id: "l1", payload: #"{"id":"l1","itemId":"a","episodeMapEvidencePaths":{"spine":"\#(voice(f1, file: "spine.json"))","\#(f3)":"x"}}"#)]),
            Fixture(name: "reply links and a resend alias name a folder-shaped id", folders: [f1, f2],
                    rows: [Row(payload: #"{"audioPath":"\#(voice(f1))","replyLinks":[{"targetId":"\#(f2)"}],"alsoSharedAs":[{"packageId":"\#(f2)"}]}"#)]),
            // The next two are written by hand to look like older rows. They were not taken from a Build 32 or 34
            // database, so they show the read copes with those shapes, not that real old rows behave.
            Fixture(name: "hand-written layer in the older shape (legacy sourceIdentity, no map fields)", folders: [f1, f2],
                    rows: [Row(kind: "imported_commentary_layer", id: "l1", payload: #"{"id":"l1","itemId":"a","packageDigest":"d","packageId":"\#(f1)","sourceIdentity":{"canonicalURL":"https://x.example/y"},"importedAt":1}"#)]),
            Fixture(name: "hand-written margin with plain optional keys only", folders: [f1, f2],
                    rows: [Row(payload: #"{"id":"m","layerId":"l1","packageScopedId":"m-001","audioPath":"\#(voice(f2))","audioDurationMs":500,"senderReadAloud":false}"#)]),
            Fixture(name: "Unicode normalisation in the file name (NFC and NFD)", folders: [f1, f2],
                    rows: [Row(payload: #"{"audioPath":"\#(voice(f1, file: "caf\u{E9}.m4a"))","x":"\#(voice(f2, file: "cafe\u{301}.m4a"))"}"#)]),
            Fixture(name: "non-ASCII text around the name", folders: [f1],
                    rows: [Row(payload: #"{"approvedTranscript":"日本語 \#(f1) émoji 🎙️"}"#)]),
            Fixture(name: "lower-case look-alike of an upper-case folder", folders: [f1],
                    rows: [Row(payload: #"{"audioPath":"\#(voice(lower))"}"#)]),
            Fixture(name: "one character off", folders: [f1, nearMiss],
                    rows: [Row(payload: #"{"audioPath":"\#(voice(nearMiss))"}"#)]),
            Fixture(name: "name with a ninth hex digit before it", folders: [f1],
                    rows: [Row(payload: #"{"audioPath":"/x/0\#(f1)/a.m4a"}"#)]),
            Fixture(name: "name with a suffix", folders: [f1],
                    rows: [Row(payload: #"{"audioPath":"/x/\#(f1)0/a.m4a"}"#)]),
            Fixture(name: "whitespace and punctuation around the name", folders: [f1, f2, f3],
                    rows: [Row(payload: #"{"a":" \#(f1) ","b":"\#(f2).","c":"_\#(f3)_"}"#)]),
            Fixture(name: "empty payloads", folders: [f1],
                    rows: [Row(payload: "{}"), Row(payload: "[]"), Row(payload: "\"\""), Row(payload: "null")]),
            Fixture(name: "very long text with the name last", folders: [f1],
                    rows: [Row(payload: #"{"approvedTranscript":"\#(longText)","audioPath":"\#(voice(f1))"}"#)]),
            Fixture(name: "name as an object key only", folders: [f1],
                    rows: [Row(payload: #"{"byId":{"\#(f1)":1}}"#)]),
            Fixture(name: "deeply nested", folders: [f1], rows: [Row(payload: nested)]),
            Fixture(name: "payload that is not valid JSON is read whole", folders: [f1, f2],
                    rows: [Row(payload: #"{"audioPath":"\#(voice(f1))","trunc"#)]),
            Fixture(name: "quarantined margin from a newer build with an unknown field", folders: [f1, f2],
                    rows: [Row(table: "quarantined_records", id: "h", itemId: nil, payload: #"{"layerId":"l1","futureVoiceLocation":{"where":"\#(voice(f1))"}}"#),
                           Row(kind: "imported_commentary_layer", id: "l1", payload: #"{"id":"l1","itemId":"a"}"#)]),
            Fixture(name: "quarantined layer of the item", folders: [f1],
                    rows: [Row(table: "quarantined_records", kind: "imported_commentary_layer", id: "l1", itemId: nil, payload: #"{"id":"l1","itemId":"a","episodeMapEvidencePaths":{"s":"\#(voice(f1))"}}"#)]),
            // A quarantined layer that is not valid JSON has no readable itemId, so no item owns it: neither the old
            // read nor this one attributes it, and the sweep keeps any folder it names. Not a fixture here.
            // The JSON text spells the first character as an escape. The read decodes strings and finds the name; the
            // sweep reads the raw text and does not. So here the read finds MORE than the sweep, never fewer. A
            // folder is only removed by the sweep's own check, so this cannot remove anything in use.
            Fixture(name: "unicode escape inside the name (read finds more)", folders: [f1],
                    rows: [Row(payload: #"{"audioPath":"/x/A\#(f1.dropFirst())/a.m4a"}"#)], mayExceedSweep: true),
        ]
    }

    func testReadMatchesTheSweepOnEveryShape() throws {
        for fixture in fixtures() {
            let (store, path, directory) = try makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try insert(fixture.rows, at: path)
            let read = try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store)
            let sweepUsed = try store.importedCommentaryRecordsMentioning(among: Set(fixture.folders))
            for folder in fixture.folders {
                let named = read.contains(folder), used = sweepUsed.contains(folder)
                if fixture.mayExceedSweep {
                    XCTAssertTrue(named || !used, "\(fixture.name): the read misses \(folder), which the sweep keeps")
                } else {
                    XCTAssertEqual(named, used, "\(fixture.name): read says \(named), sweep says \(used) for \(folder)")
                }
            }
        }
    }

    /// The read must find something in most shapes, or agreeing on "nothing" would pass.
    func testTheTableIsNotVacuous() throws {
        var found = 0
        for fixture in fixtures() {
            let (store, path, directory) = try makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            try insert(fixture.rows, at: path)
            if !(try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store)).isEmpty { found += 1 }
        }
        XCTAssertGreaterThan(found, 20)
    }

    /// The point of #3410: whole payloads must not cross into Swift. The store's read meter counts the bytes each
    /// read hands to Swift; the old read handed over every payload (about 10 MB here), this one a few hundred bytes.
    func testNoPayloadCrossesIntoSwift() throws {
        let meter = StoreReadMeter()
        let (store, path, directory) = try makeStore(meter: meter)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filler = String(repeating: "a shared map spans many words ", count: 3_400)
        var rows: [Row] = []
        for index in 0..<50 {
            rows.append(Row(id: "m\(index)", payload: #"{"approvedTranscript":"\#(filler)","audioPath":"\#(voice(UUID().uuidString))"}"#))
        }
        let sketch = (0..<60_000).map { "\"h\($0)abcdefgh\"" }.joined(separator: ",")
        rows.append(Row(kind: "imported_commentary_layer", id: "l1", payload: #"{"id":"l1","itemId":"a","transcriptPhraseSketches":[{"windows":[\#(sketch)]}],"episodeMapEvidencePaths":{"s":"\#(voice(f1))"}}"#))
        try insert(rows, at: path)

        let names = try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store)

        let totals = meter.totals()
        let bytes = totals.values.reduce(0) { $0 + $1.bytes }
        XCTAssertLessThan(bytes, 20_000, "payloads reached Swift: \(totals)")
        XCTAssertEqual(names.count, 51)
        XCTAssertTrue(names.contains(f1))
    }

    /// A folder named only inside a bulk artifact field (a sketch) is not a candidate: the field is cut out before
    /// the walk. Real writers put a recipient's folder only in `audioPath`, `podcastAnchorEvidence[].localPath` and
    /// `episodeMapEvidencePaths` (SharingFoundation.swift), never in these fields. The sweep keeps such a name while
    /// the row exists, and the launch sweep takes the folder once the row is gone.
    func testAFolderNamedOnlyInABulkArtifactFieldIsNotACandidate() throws {
        let (store, path, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try insert([Row(kind: "imported_commentary_layer", id: "l1", payload: #"{"id":"l1","itemId":"a","transcriptPhraseSketches":[{"note":"\#(f2)"}],"episodeMapEvidencePaths":{"s":"\#(voice(f1))"}}"#)], at: path)

        XCTAssertEqual(try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store), [f1])
        XCTAssertEqual(try store.importedCommentaryRecordsMentioning(among: [f1, f2]), [f1, f2])
    }

    /// A folder named only inside a string over 2 KB (a transcript) is not a candidate: the sweep keeps it while the
    /// row exists, nothing removes it at the delete, and the launch sweep takes it once the row is gone.
    func testAFolderNamedOnlyInsideLongFreeTextIsNotACandidate() throws {
        let (store, path, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "x ", count: 1500) + f2
        try insert([Row(payload: #"{"approvedTranscript":"\#(text)","audioPath":"\#(voice(f1))"}"#)], at: path)

        XCTAssertEqual(try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store), [f1])
        XCTAssertEqual(try store.importedCommentaryRecordsMentioning(among: [f1, f2]), [f1, f2])
    }

    func testAnotherItemsRowsAreNotRead() throws {
        let (store, path, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try insert([Row(itemId: "b", payload: #"{"audioPath":"\#(voice(f1))"}"#),
                    Row(kind: "turn", itemId: "a", payload: #"{"text":"\#(f2)"}"#)], at: path)

        XCTAssertEqual(try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store), [])
    }

    /// The issue's case: about 10 MB of imported payloads under one item. Prints the time; asserts only that the
    /// names are right, since a time depends on the machine and the build.
    func testTenMegabytesOfImportedPayloads() throws {
        let (store, path, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let filler = String(repeating: "a shared map spans many words ", count: 3_400) // about 100 KB
        var rows: [Row] = []
        for index in 0..<100 {
            let folder = index == 0 ? f1 : UUID().uuidString
            rows.append(Row(id: "m\(index)", payload: #"{"id":"m\#(index)","approvedTranscript":"\#(filler)","audioPath":"\#(voice(folder))"}"#))
        }
        try insert(rows, at: path)

        let start = Date()
        let names = try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store)
        print("FRIEND_FOLDER_READ_SECONDS \(Date().timeIntervalSince(start))")

        XCTAssertEqual(names.count, 100)
        XCTAssertTrue(names.contains(f1))
    }

    /// A layer carrying a phrase sketch at the 5 MB artifact cap (windows of 24 hashes). Prints the time.
    func testLayerWithFiveMegabyteSketch() throws {
        let (store, path, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        var windows: [String] = []
        var size = 0
        while size < 5 * 1_024 * 1_024 {
            let hashes = (0..<24).map { _ in "\"\(Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString())\"" }
            let window = #"{"id":"w\#(windows.count)","sourceStartMs":\#(windows.count * 1000),"sourceEndMs":\#(windows.count * 1000 + 999),"hashes":[\#(hashes.joined(separator: ","))]}"#
            windows.append(window)
            size += window.utf8.count
        }
        try insert([Row(kind: "imported_commentary_layer", id: "l1", payload: #"{"id":"l1","itemId":"a","transcriptPhraseSketches":[{"id":"s1","itemId":"a","windows":[\#(windows.joined(separator: ","))]}],"episodeMapEvidencePaths":{"s":"\#(voice(f1))"}}"#)], at: path)

        let start = Date()
        let names = try FriendPacketFolders.candidateFolderNames(ofItems: ["a"], store: store)
        print("FRIEND_FOLDER_SKETCH_READ_SECONDS \(Date().timeIntervalSince(start)) payload_bytes \(size)")

        XCTAssertEqual(names, [f1])
    }

    private func insert(_ rows: [Row], at path: String) throws {
        for row in rows {
            if row.table == "records" {
                try StoreRawSQL.execute(
                    "INSERT INTO records(kind, id, session_id, item_id, payload) VALUES (?, ?, NULL, ?, ?);",
                    bindings: [row.kind, row.id, row.itemId, row.payload], at: path)
            } else {
                try StoreRawSQL.execute(
                    "INSERT INTO quarantined_records(kind, id, payload, decode_error) VALUES (?, ?, ?, 'x');",
                    bindings: [row.kind, row.id, row.payload], at: path)
            }
        }
    }

    private func makeStore(meter: StoreReadMeter? = nil) throws -> (SQLiteSessionStore, String, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("friend-candidates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("library.sqlite").path
        return (try SQLiteSessionStore(path: path, readMeter: meter), path, directory)
    }
}
