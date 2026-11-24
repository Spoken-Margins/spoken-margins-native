import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// The sender's app remembers the run-up length each Margin was last shared with (#4171, PR 4a), the way it remembers the
/// read-aloud choice (#3472, `ReadAloudChoiceTests`). Runs on Linux; `ShareDraftLeadInTests` (Mac only) covers the draft
/// that reads and writes it.
final class SenderLeadInMemoryTests: XCTestCase {
    func testWhereTheShareSheetStartsAMargin() {
        let d = SenderLeadIn.defaultMs
        let table: [(Int?, Int)] = [
            (nil, d),               // never shared with a length
            (d, d),
            (60_000, 60_000),
            (5_000, 5_000),
            (0, 0),                 // 0 is a length, not "nothing"
            (900_000, 300_000),     // a stored value past the reader's range
            (-5, 0),
            (Int.max, 300_000),
            (Int.min, 0),
        ]
        for (lastSent, starts) in table {
            XCTAssertEqual(SenderLeadIn.startingMs(lastSent: lastSent), starts, "last sent \(String(describing: lastSent))")
        }
    }

    private func revision(_ id: String, margin: String, at seconds: Double, sent: Int?, item: String = "item") -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: id, interjectionId: margin, itemId: item, sessionId: "session",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000 + seconds), approvedTranscript: "Words.",
            anchorBefore: "Before", anchorAfter: "After", status: .senderApproved, sentLeadInMs: sent
        )
    }

    private func openStore() throws -> (SQLiteSessionStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SenderLeadInMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    /// A share saved by an earlier build has no length; a share that wrote none stores none. A previous build, which
    /// doesn't know the key, reads the same record it always wrote.
    func testAShareThatWroteNoLengthIsStoredExactlyAsBefore() throws {
        let encoded = String(decoding: try JSONEncoder().encode(revision("n", margin: "m", at: 0, sent: nil)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sentLeadInMs"))
        let old = #"{"id":"r","interjectionId":"m","itemId":"item","sessionId":"s","createdAt":0,"cleanupPolicyVersion":"cleanup.v1","approvedTranscript":"Words.","decisions":[],"anchorBefore":"B","anchorAfter":"A","status":"sender_approved"}"#
        XCTAssertNil(try JSONDecoder().decode(InterjectionShareRevision.self, from: Data(old.utf8)).sentLeadInMs)
        let withLength = String(decoding: try JSONEncoder().encode(revision("n", margin: "m", at: 0, sent: 60_000)), as: UTF8.self)
        XCTAssertTrue(withLength.contains("\"sentLeadInMs\":60000"))
    }

    /// Share ids are random and `updated_at` counts whole seconds, so two shares of one Margin saved back to back tie on
    /// time; the later save has to win whatever its id sorts as.
    func testTheLibraryRemembersEachMarginsNewestLengthPerItem() throws {
        let (store, folder) = try openStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.saveInterjectionShareRevision(revision("z", margin: "one", at: 1, sent: 60_000))
        try store.saveInterjectionShareRevision(revision("a", margin: "one", at: 1, sent: 30_000)) // same second; "a" sorts first
        try store.saveInterjectionShareRevision(revision("y", margin: "two", at: 1, sent: 120_000))
        try store.saveInterjectionShareRevision(revision("b", margin: "two", at: 2, sent: nil))    // wrote none: leaves 120 000
        try store.saveInterjectionShareRevision(revision("c", margin: "three", at: 2, sent: nil))
        try store.saveInterjectionShareRevision(revision("d", margin: "elsewhere", at: 2, sent: 45_000, item: "another item"))
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "item"), ["session::one": 30_000, "session::two": 120_000])
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "another item"), ["session::elsewhere": 45_000])
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "no such item"), [:])
        // Taking a length back stores 20 s, so the next share knows the friend was told.
        try store.saveInterjectionShareRevision(revision("e", margin: "two", at: 3, sent: SenderLeadIn.defaultMs))
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "item")["session::two"], SenderLeadIn.defaultMs)
    }

    /// The loop the sheet will run for one Margin: share at a minute, share again unchanged, take it back, share again
    /// unchanged. The packet says 60 s twice, then 20 s once, then nothing, and the store follows what was said.
    func testShareAtAMinuteThenLeaveItThenTakeItBackSaysTwentyOnceThenNothing() throws {
        let (store, folder) = try openStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        func share(_ at: Double, picks chosen: Int?) throws -> Int? {
            let last = try store.loadLastSentLeadIns(itemId: "item")["session::m"]
            let start = SenderLeadIn.startingMs(lastSent: last)
            let written = SenderLeadIn.valueToWrite(chosen: chosen ?? start, previous: last)
            try store.saveInterjectionShareRevision(revision("share-\(at)", margin: "m", at: at, sent: written))
            return written
        }
        XCTAssertEqual(try share(1, picks: 60_000), 60_000)
        XCTAssertEqual(try share(2, picks: nil), 60_000, "left alone, the sheet starts at a minute and the friend's copy stays there")
        XCTAssertEqual(try share(3, picks: SenderLeadIn.defaultMs), SenderLeadIn.defaultMs)
        XCTAssertNil(try share(4, picks: nil), "after a share that said 20 s there is nothing more to say")
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "item")["session::m"], SenderLeadIn.defaultMs)
    }
}
