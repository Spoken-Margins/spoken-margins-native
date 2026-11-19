import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest

/// The sender's share draft carries how much of the episode a friend hears before a Margin (#4171, PR 4a). There is no
/// row for it on screen yet; these tests pin the plumbing the row will use: where a draft starts, what the packet and the
/// saved share write, and that the next share starts from what the friend was last told.
final class ShareDraftLeadInTests: XCTestCase {
    private func margin(id: String = "margin-1") -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000), roughPercent: 40,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: 754_900),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "completed", transcript: "Remember this.",
            cleanedTranscript: nil, displayText: nil, status: "active", captureKind: .written
        )
    }

    private func draft(_ id: String = "margin-1", lastSentLeadInMs: Int? = nil) -> ShareInterjectionDraft {
        ShareInterjectionDraft.initial(
            for: margin(id: id), isIncluded: true, hasVoice: false, itemTitle: "T",
            lastSentLeadInMs: lastSentLeadInMs
        )
    }

    private func revision(for draft: ShareInterjectionDraft, id: String, at seconds: Double) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: id, interjectionId: draft.interjection.id, itemId: "item", sessionId: "session",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000 + seconds), approvedTranscript: "Words.",
            anchorBefore: "Before", anchorAfter: "After", status: .senderApproved, sentLeadInMs: draft.leadInToWrite
        )
    }

    private func openStore() throws -> (SQLiteSessionStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShareDraftLeadIn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    // MARK: Where a draft starts

    func testAMarginNeverSharedWithALengthStartsAtTheDefaultAndWritesNothing() {
        let fresh = draft()
        XCTAssertEqual(fresh.leadInMs, SenderLeadIn.defaultMs)
        XCTAssertNil(fresh.previousLeadInMs)
        XCTAssertNil(fresh.leadInToWrite, "a packet in which no length was ever changed stays what today's build writes")
    }

    func testAReShareStartsFromTheLengthTheFriendWasLastGiven() {
        let again = draft(lastSentLeadInMs: 60_000)
        XCTAssertEqual(again.leadInMs, 60_000)
        XCTAssertEqual(again.previousLeadInMs, 60_000)
        XCTAssertEqual(again.leadInToWrite, 60_000, "an unchanged length is written again, so a re-sent packet keeps the friend's copy there")
    }

    func testALengthTheSenderSetsIsWritten() {
        var picked = draft()
        picked.leadInMs = 60_000
        XCTAssertEqual(picked.leadInToWrite, 60_000)
        picked.leadInMs = 5_000
        XCTAssertEqual(picked.leadInToWrite, 5_000)
    }

    func testTakingTheLengthBackIsWrittenOutLoud() {
        var back = draft(lastSentLeadInMs: 60_000)
        back.leadInMs = SenderLeadIn.defaultMs
        XCTAssertEqual(back.leadInToWrite, SenderLeadIn.defaultMs, "a missing key can't tell the friend's held copy to return to 20 s")
        var stillDefault = draft(lastSentLeadInMs: SenderLeadIn.defaultMs)
        stillDefault.leadInMs = SenderLeadIn.defaultMs
        XCTAssertNil(stillDefault.leadInToWrite, "after a share that already said 20 s, nothing more to say")
    }

    func testAStoredLengthOutsideWhatAReaderAcceptsIsClampedWhereTheDraftStarts() {
        XCTAssertEqual(draft(lastSentLeadInMs: 900_000).leadInMs, SenderLeadIn.range.upperBound)
        XCTAssertEqual(draft(lastSentLeadInMs: -5).leadInMs, SenderLeadIn.range.lowerBound)
    }

    func testEditingTheDraftNeverTouchesTheLength() {
        var edited = draft(lastSentLeadInMs: 45_000)
        edited.restoreOriginal(hasOriginalAudio: false)
        edited.setIncluded(false)
        edited.setReviewedWords("Other words.")
        XCTAssertEqual(edited.leadInMs, 45_000)
        XCTAssertEqual(edited.previousLeadInMs, 45_000)
    }

    // MARK: The saved share

    /// A stored share from before the sender could choose has no `sentLeadInMs`, and a share that wrote none stores
    /// none, so the record a previous build reads is exactly the one it wrote.
    func testAShareThatWroteNoLengthIsStoredExactlyAsBefore() throws {
        let plain = revision(for: draft(), id: "r", at: 0)
        XCTAssertNil(plain.sentLeadInMs)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("sentLeadInMs"))
        let old = #"{"id":"r","interjectionId":"m","itemId":"item","sessionId":"s","createdAt":0,"cleanupPolicyVersion":"cleanup.v1","approvedTranscript":"Words.","decisions":[],"anchorBefore":"B","anchorAfter":"A","status":"sender_approved"}"#
        XCTAssertNil(try JSONDecoder().decode(InterjectionShareRevision.self, from: Data(old.utf8)).sentLeadInMs)
    }

    /// Share ids are random and `updated_at` counts whole seconds, so two shares saved back to back tie on time; the later
    /// save has to win whatever its id sorts as, as it does for the read-aloud choice.
    func testTheLibraryRemembersEachMarginsNewestLengthPerItem() throws {
        let (store, folder) = try openStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var one = draft("one"); one.leadInMs = 60_000
        var oneLater = draft("one", lastSentLeadInMs: 60_000); oneLater.leadInMs = 30_000
        var two = draft("two"); two.leadInMs = 120_000
        let twoPlain = draft("two", lastSentLeadInMs: 120_000) // unchanged: writes 120 000 again
        var twoBack = draft("two", lastSentLeadInMs: 120_000); twoBack.leadInMs = SenderLeadIn.defaultMs
        let three = draft("three") // never changed: stores no length
        try store.saveInterjectionShareRevision(revision(for: one, id: "z", at: 1))
        try store.saveInterjectionShareRevision(revision(for: oneLater, id: "a", at: 1)) // same second, sorts first by id
        try store.saveInterjectionShareRevision(revision(for: two, id: "y", at: 1))
        try store.saveInterjectionShareRevision(revision(for: twoPlain, id: "b", at: 2))
        try store.saveInterjectionShareRevision(revision(for: three, id: "c", at: 2))
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "item"), ["one": 30_000, "two": 120_000])
        // Taking a length back stores 20 s, so the next share knows the friend was told.
        try store.saveInterjectionShareRevision(revision(for: twoBack, id: "d", at: 3))
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "item"), ["one": 30_000, "two": SenderLeadIn.defaultMs])
        XCTAssertEqual(try store.loadLastSentLeadIns(itemId: "another item"), [:])
    }

    /// The whole loop the sheet will run: share at a minute, share again with it taken back, share a third time with
    /// nothing changed. The packet says 20 s once, and then nothing.
    func testShareAtAMinuteThenTakeItBackThenLeaveItSaysTwentyOnceThenNothing() throws {
        let (store, folder) = try openStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        func next(_ at: Double, _ pick: (inout ShareInterjectionDraft) -> Void) throws -> Int? {
            let last = try store.loadLastSentLeadIns(itemId: "item")["m"]
            var d = draft("m", lastSentLeadInMs: last)
            pick(&d)
            try store.saveInterjectionShareRevision(revision(for: d, id: "share-\(at)", at: at))
            return d.leadInToWrite
        }
        XCTAssertEqual(try next(1) { $0.leadInMs = 60_000 }, 60_000)
        XCTAssertEqual(try next(2) { _ in }, 60_000, "a re-share with no change keeps the friend's copy at a minute")
        XCTAssertEqual(try next(3) { $0.leadInMs = SenderLeadIn.defaultMs }, SenderLeadIn.defaultMs)
        XCTAssertNil(try next(4) { _ in })
    }
}
