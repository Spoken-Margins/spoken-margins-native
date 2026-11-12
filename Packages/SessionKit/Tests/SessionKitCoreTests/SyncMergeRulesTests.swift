import Foundation
import XCTest
@testable import SessionKit

/// #4152: the rules that decide how a listener's devices end up with the same Margins, Spoken Notes and place. Each
/// test names the rule it holds; the simulator in `SyncConvergenceSimulatorTests` checks them together under bad networks.
final class SyncMergeRulesTests: XCTestCase {
    private let t0: Int64 = 1_760_000_000_000
    private let day: Int64 = 86_400_000
    private let marginID = SyncRecordID.margin("m1")

    /// Two phones and a cloud, both having already synced one Margin whose text is "first".
    private func twoPhonesWithOneMargin() throws -> (a: SyncReplica, b: SyncReplica, cloud: SyncTestCloud) {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        try a.edit(marginID) { record, clock in
            record = try! MarginSync.record(for: SyncFixtures.margin(id: "m1", text: "first"), itemKey: "ep-1", clock: &clock, wallMillis: self.t0)
        }
        a.syncNow(with: &cloud, nowMillis: t0)
        b.syncNow(with: &cloud, nowMillis: t0)
        XCTAssertEqual(b.record(marginID)?["transcript"]?.stringValue, "first")
        return (a, b, cloud)
    }

    private func set(_ replica: inout SyncReplica, _ id: SyncRecordID, _ field: String, _ text: String, at millis: Int64) throws {
        try replica.edit(id) { record, clock in record.set(field, .string(text), clock: &clock, wallMillis: millis) }
    }

    private func syncBoth(_ a: inout SyncReplica, _ b: inout SyncReplica, _ cloud: inout SyncTestCloud, at millis: Int64) {
        for _ in 0..<2 {
            a.syncNow(with: &cloud, nowMillis: millis)
            b.syncNow(with: &cloud, nowMillis: millis)
        }
    }

    // MARK: - The version stamp does not trust the wall clock alone

    func testClockNeverIssuesAStampAtOrBelowOneItHasSeen() {
        var clock = SyncClock(device: "A")
        let first = clock.tick(wallMillis: 1000)
        XCTAssertGreaterThan(clock.tick(wallMillis: 500), first, "a clock set back")
        XCTAssertGreaterThan(clock.tick(wallMillis: 500), first)
        let far = SyncStamp(wallMillis: 9_000_000, counter: 4, device: "B")
        clock.observe(far)
        XCTAssertGreaterThan(clock.tick(wallMillis: 10), far, "after a stamp from a phone whose clock runs ahead")
        let sameMillisecond = clock.tick(wallMillis: 9_000_000)
        XCTAssertGreaterThan(sameMillisecond, far)
    }

    func testAPhoneWithAWrongClockDoesNotWinAfterItHasSeenTheEdit() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "displayText", "from A", at: t0 + 1000)
        a.syncNow(with: &cloud, nowMillis: t0 + 1000)
        b.syncNow(with: &cloud, nowMillis: t0 + 1000)
        // B's clock is a year behind. It has seen A's edit, so its edit is later, whatever its clock says.
        try set(&b, marginID, "displayText", "from B, later", at: t0 - 365 * day)
        syncBoth(&a, &b, &cloud, at: t0 + 2000)
        XCTAssertEqual(a.record(marginID)?["displayText"]?.stringValue, "from B, later")
        XCTAssertEqual(b.record(marginID)?["displayText"]?.stringValue, "from B, later")
        XCTAssertEqual(a.record(marginID)?.otherVersions(of: "displayText"), [], "not a race: B had seen A's edit")
    }

    func testAPhoneWhoseClockRunsAheadOnlyWinsUntilTheOthersHaveSeenIt() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "displayText", "A, a year ahead", at: t0 + 365 * day)
        syncBoth(&a, &b, &cloud, at: t0 + 1000)
        try set(&b, marginID, "displayText", "B, afterwards", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertEqual(a.record(marginID)?["displayText"]?.stringValue, "B, afterwards")
        XCTAssertEqual(b.record(marginID)?["displayText"]?.stringValue, "B, afterwards")
    }

    // MARK: - Per-field merge

    func testEditsToDifferentFieldsOfOneMarginBothSurvive() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "displayText", "A's words", at: t0 + 1000)
        try set(&b, marginID, "privateSharingNote", "B's note", at: t0 + 1500)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        for replica in [a, b] {
            XCTAssertEqual(replica.record(marginID)?["displayText"]?.stringValue, "A's words")
            XCTAssertEqual(replica.record(marginID)?["privateSharingNote"]?.stringValue, "B's note")
        }
        XCTAssertEqual(a.records, b.records)
    }

    func testARaceOnOneTextFieldKeepsTheLosingTextAsAnotherVersion() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "transcript", "A's version", at: t0 + 1000)
        try set(&b, marginID, "transcript", "B's version", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        for replica in [a, b] {
            XCTAssertEqual(replica.record(marginID)?["transcript"]?.stringValue, "B's version", "the later edit is shown")
            XCTAssertEqual(replica.record(marginID)?.otherVersions(of: "transcript"), [.string("A's version")], "the other is kept")
        }
        // The listener picks the other version; it stays picked even when the old copies arrive again.
        var picked = a
        try picked.edit(marginID) { record, clock in record.resolve("transcript", to: .string("A's version"), clock: &clock, wallMillis: self.t0 + 4000) }
        let stale = b.records[marginID]!
        picked.receive([stale])
        picked.syncNow(with: &cloud, nowMillis: t0 + 4000)
        b.syncNow(with: &cloud, nowMillis: t0 + 4000)
        for replica in [picked, b] {
            XCTAssertEqual(replica.record(marginID)?["transcript"]?.stringValue, "A's version")
            XCTAssertEqual(replica.record(marginID)?.otherVersions(of: "transcript"), [])
        }
    }

    func testAnEditMadeAfterSeeingAnotherIsNotARace() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "transcript", "A's version", at: t0 + 1000)
        syncBoth(&a, &b, &cloud, at: t0 + 1500)
        try set(&b, marginID, "transcript", "B's edit of it", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertEqual(a.record(marginID)?["transcript"]?.stringValue, "B's edit of it")
        XCTAssertEqual(a.record(marginID)?.otherVersions(of: "transcript"), [])
    }

    func testAnEditOnADeviceThatHoldsBothVersionsSettlesTheFieldButAVersionNotYetSeenSurvives() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "transcript", "A's version", at: t0 + 1000)
        try set(&b, marginID, "transcript", "B's version", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        try set(&a, marginID, "transcript", "B's version, fixed", at: t0 + 4000)   // A holds both and edits: its choice
        try set(&b, marginID, "transcript", "B's other edit", at: t0 + 4500)       // B, meanwhile, had not seen the fix
        syncBoth(&a, &b, &cloud, at: t0 + 5000)
        XCTAssertEqual(a.record(marginID)?["transcript"]?.stringValue, "B's other edit")
        XCTAssertEqual(a.record(marginID)?.otherVersions(of: "transcript"), [.string("B's version, fixed")], "the edit B had not seen is kept")
        XCTAssertEqual(a.records, b.records)
    }

    func testTheSameTextTypedOnTwoPhonesIsNotAnOtherVersion() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "transcript", "same", at: t0 + 1000)
        try set(&b, marginID, "transcript", "same", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertEqual(a.record(marginID)?.otherVersions(of: "transcript"), [])
    }

    // MARK: - Delete and undelete

    func testADeleteBeatsAnEarlierEditAndKeepsItsWords() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "displayText", "edited", at: t0 + 1000)
        syncBoth(&a, &b, &cloud, at: t0 + 1500)
        try b.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0 + 2000) }
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        for replica in [a, b] {
            XCTAssertTrue(try XCTUnwrap(replica.record(marginID)).isDeleted)
            XCTAssertEqual(replica.record(marginID)?["displayText"]?.stringValue, "edited", "a delete keeps the words, as one phone does")
        }
    }

    func testADeleteAndARacingEditLeaveItDeletedWithTheEditKept() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try a.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0 + 1000) }
        try set(&b, marginID, "displayText", "typed on B", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        for replica in [a, b] {
            XCTAssertTrue(try XCTUnwrap(replica.record(marginID)).isDeleted)
            XCTAssertEqual(replica.record(marginID)?["displayText"]?.stringValue, "typed on B")
        }
    }

    func testAnUndeleteAfterTheDeleteWinsAndAStaleDeleteDoesNotUndoIt() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        try a.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0 + 1000) }
        syncBoth(&a, &b, &cloud, at: t0 + 1500)
        let deletedCopy = try XCTUnwrap(b.record(marginID))
        try b.edit(marginID) { record, clock in record.markActive(clock: &clock, wallMillis: self.t0 + 2000) }
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        a.receive([deletedCopy])
        b.receive([deletedCopy])
        syncBoth(&a, &b, &cloud, at: t0 + 4000)
        for replica in [a, b] { XCTAssertFalse(try XCTUnwrap(replica.record(marginID)).isDeleted) }
    }

    // MARK: - Applying a change twice, in any order

    func testTheSameChangeAppliedTwiceOrInAnyOrderGivesTheSameRecord() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        let base = try a.edit(marginID) { record, clock in
            record = try! MarginSync.record(for: SyncFixtures.margin(id: "m1", text: "first"), itemKey: "ep-1", clock: &clock, wallMillis: self.t0)
        }
        b.receive([base])
        try set(&a, marginID, "transcript", "A", at: t0 + 1000)
        try set(&b, marginID, "transcript", "B", at: t0 + 1500)
        try b.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0 + 2000) }
        let changes = [base, a.record(marginID)!, b.record(marginID)!]
        var results: [SyncRecord] = []
        for order in [[0, 1, 2], [2, 1, 0], [1, 2, 0], [1, 1, 2, 2, 0, 0, 1], [2, 0, 2, 1]] {
            var replica = SyncReplica(device: "C")
            replica.receive(order.map { changes[$0] })
            results.append(try XCTUnwrap(replica.record(marginID)))
        }
        XCTAssertTrue(results.dropFirst().allSatisfy { $0 == results[0] }, "every order and repeat gives one record")
    }

    func testADeleteThatArrivesBeforeTheAddGivesTheSameResultAndShowsNothingUntilTheAdd() throws {
        var a = SyncReplica(device: "A")
        let full = try a.edit(marginID) { record, clock in
            record = try! MarginSync.record(for: SyncFixtures.margin(id: "m1"), itemKey: "ep-1", clock: &clock, wallMillis: self.t0)
        }
        var deleteOnly = SyncRecord(id: marginID)
        var other = SyncClock(device: "B")
        other.observe(full.highestStamp!)
        deleteOnly.markDeleted(clock: &other, wallMillis: t0 + 5000)

        var deleteFirst = SyncReplica(device: "C")
        deleteFirst.receive([deleteOnly])
        XCTAssertFalse(MarginSync.isMaterializable(try XCTUnwrap(deleteFirst.record(marginID))), "no Margin to show without its record")
        deleteFirst.receive([full])
        var addFirst = SyncReplica(device: "D")
        addFirst.receive([full])
        addFirst.receive([deleteOnly])
        XCTAssertEqual(deleteFirst.record(marginID), addFirst.record(marginID))
        XCTAssertTrue(MarginSync.isMaterializable(try XCTUnwrap(addFirst.record(marginID))))
        XCTAssertTrue(try XCTUnwrap(addFirst.record(marginID)).isDeleted)
    }

    // MARK: - Margins and Spoken Notes as models

    func testMarginRecordCarriesTheListenersWordsAndLeavesTheDevicesOwnFieldsAlone() throws {
        var clock = SyncClock(device: "A")
        var margin = SyncFixtures.margin(id: "m1", text: "heard it")
        margin.privateSharingNote = "for Sam"
        margin.isStarredForSharing = true
        let record = try MarginSync.record(for: margin, itemKey: "ep-1", clock: &clock, wallMillis: t0)
        XCTAssertTrue(MarginSync.isMaterializable(record))
        XCTAssertEqual(MarginSync.itemKey(of: record), "ep-1")

        var onOtherPhone = SyncFixtures.margin(id: "m1", text: "old")
        onOtherPhone.audioPath = "recordings/other.m4a"
        onOtherPhone.itemId = "that-phones-item"
        let applied = MarginSync.apply(record, to: onOtherPhone)
        XCTAssertEqual(applied.transcript, "heard it")
        XCTAssertEqual(applied.privateSharingNote, "for Sam")
        XCTAssertEqual(applied.isStarredForSharing, true)
        XCTAssertEqual(applied.audioPath, "recordings/other.m4a", "the recording is not synced yet")
        XCTAssertEqual(applied.itemId, "that-phones-item", "a Margin belongs to an item key, not to a local item id")
        XCTAssertEqual(applied.anchor, onOtherPhone.anchor)
        XCTAssertEqual(try record["anchor"]?.decoded(as: Anchor.self), margin.anchor)
    }

    func testWritingAnEditedMarginWritesOnlyWhatTheListenerChanged() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        let base = SyncFixtures.margin(id: "m1", text: "first")
        // Two phones race on the transcript; A holds both versions.
        try set(&a, marginID, "transcript", "A's version", at: t0 + 1000)
        try set(&b, marginID, "transcript", "B's version", at: t0 + 2000)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        // B deletes the Margin; A has not applied that to its Margin yet.
        try b.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0 + 3500) }
        b.syncNow(with: &cloud, nowMillis: t0 + 3600)
        // On A the listener edits only the private note, from a Margin whose transcript and status are stale.
        var edited = base
        edited.transcript = "B's version"
        edited.privateSharingNote = "for Sam"
        var before = base
        before.transcript = "B's version"
        try a.edit(marginID) { record, clock in
            MarginSync.write(edited, changedFrom: before, into: &record, clock: &clock, wallMillis: self.t0 + 4000)
        }
        syncBoth(&a, &b, &cloud, at: t0 + 5000)
        for replica in [a, b] {
            XCTAssertEqual(replica.record(marginID)?["privateSharingNote"]?.stringValue, "for Sam")
            XCTAssertEqual(replica.record(marginID)?.otherVersions(of: "transcript"), [.string("A's version")], "the waiting version was not replaced by a copy of the current one")
            XCTAssertTrue(try XCTUnwrap(replica.record(marginID)).isDeleted, "a stale 'active' did not undelete it")
        }
    }

    func testPrivateFieldsAndWordsAreEncryptedAndOnlyTheDeleteStateAndTimeAreNot() {
        for field in MarginSync.textFields + ["isStarredForSharing", "anchor", "itemKey"] + SpokenNoteSync.textFields {
            XCTAssertTrue(SyncFieldSchema.isEncrypted(field: field), field)
        }
        XCTAssertFalse(SyncFieldSchema.isEncrypted(field: "status"))
    }

    func testASpokenNoteMergesItsTextByTheMarginRuleAndIsKeyedByItsNoteId() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        let noteRecord = try a.edit(.item(SpokenNoteItem.itemId(forNoteId: "n1"))) { record, clock in
            record = SpokenNoteSync.record(noteId: "n1", title: "Groceries", text: "milk", createdAt: Date(timeIntervalSince1970: 1), clock: &clock, wallMillis: self.t0)
        }
        XCTAssertEqual(noteRecord.id, .item("spoken-note-n1"))
        syncBoth(&a, &b, &cloud, at: t0)
        try set(&a, noteRecord.id, "text", "milk, eggs", at: t0 + 1000)
        try set(&b, noteRecord.id, "text", "milk, bread", at: t0 + 1100)
        try set(&b, noteRecord.id, "title", "Shopping", at: t0 + 1200)
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertEqual(a.records, b.records)
        XCTAssertEqual(a.record(noteRecord.id)?["text"]?.stringValue, "milk, bread")
        XCTAssertEqual(a.record(noteRecord.id)?.otherVersions(of: "text"), [.string("milk, eggs")], "no words of the listener's are lost")
        XCTAssertEqual(a.record(noteRecord.id)?["title"]?.stringValue, "Shopping")
    }

    func testAnEditFromAnotherPhoneNeverBringsATrashedSpokenNoteBack() {
        var clock = SyncClock(device: "A")
        let record = SpokenNoteSync.record(noteId: "n1", title: "T", text: "new words", createdAt: Date(timeIntervalSince1970: 1), clock: &clock, wallMillis: t0)
        var trashed = SpokenNoteItem.makeItem(note: SpokenNote(id: "n1"), title: "T", createdAt: Date(timeIntervalSince1970: 1))
        trashed.deletedAt = Date(timeIntervalSince1970: 5)
        XCTAssertNil(SpokenNoteSync.rowToSave(stored: trashed, record: record, noteId: "n1"))

        let live = SpokenNoteItem.makeItem(note: SpokenNote(id: "n1"), title: "T", createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(SpokenNoteSync.rowToSave(stored: live, record: record, noteId: "n1")?.text, "new words")
        XCTAssertEqual(SpokenNoteSync.rowToSave(stored: nil, record: record, noteId: "n1")?.id, "spoken-note-n1", "a note this phone lacks becomes an item")
    }

    // MARK: - Collections: order merges by item key

    func testAnItemAddedOnOnePhoneAndAReorderOnAnotherBothStay() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        let id = SyncRecordID.collection("c1")
        try a.edit(id) { record, clock in record = CollectionSync.create(id: "c1", name: "Course", itemKeys: ["a", "b", "c"], clock: &clock, wallMillis: self.t0) }
        syncBoth(&a, &b, &cloud, at: t0)
        try a.edit(id) { record, clock in CollectionSync.add("d", to: &record, clock: &clock, wallMillis: self.t0 + 1000) }
        try b.edit(id) { record, clock in CollectionSync.reorder(["c", "b", "a"], in: &record, clock: &clock, wallMillis: self.t0 + 2000) }
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertEqual(CollectionSync.orderedItemKeys(of: try XCTUnwrap(a.record(id))), ["c", "b", "a", "d"], "the newer order wins; the item added on the older side goes last")
        XCTAssertEqual(a.records, b.records)
    }

    func testTheNewerOrderWinsWhoeverMadeItFirstAndARemovalIsAnEditToo() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        let id = SyncRecordID.collection("c1")
        try a.edit(id) { record, clock in record = CollectionSync.create(id: "c1", name: "Course", itemKeys: ["a", "b", "c"], clock: &clock, wallMillis: self.t0) }
        syncBoth(&a, &b, &cloud, at: t0)
        try b.edit(id) { record, clock in CollectionSync.reorder(["c", "a", "b"], in: &record, clock: &clock, wallMillis: self.t0 + 1000) }
        try a.edit(id) { record, clock in CollectionSync.reorder(["b", "a", "c"], in: &record, clock: &clock, wallMillis: self.t0 + 2000) }
        try b.edit(id) { record, clock in CollectionSync.remove("a", from: &record, clock: &clock, wallMillis: self.t0 + 2500) }
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertEqual(CollectionSync.orderedItemKeys(of: try XCTUnwrap(b.record(id))), ["b", "c"])
        XCTAssertEqual(a.records, b.records)
        try a.edit(id) { record, clock in CollectionSync.add("a", to: &record, clock: &clock, wallMillis: self.t0 + 4000) }
        syncBoth(&a, &b, &cloud, at: t0 + 5000)
        XCTAssertEqual(Set(CollectionSync.orderedItemKeys(of: try XCTUnwrap(b.record(id)))), ["a", "b", "c"], "an item added back stays")
    }

    // MARK: - The listening place

    private func playRecord(_ replica: inout SyncReplica, item: String, ms: Int, revision: String = "rev-1", cause: ListeningPlaceSync.Cause = .play, at millis: Int64) throws {
        try replica.edit(.place(item)) { record, clock in
            ListeningPlaceSync.recordPlay(position: .number(Double(ms)), sourceRevision: revision, cause: cause, in: &record, clock: &clock, atMillis: millis)
        }
    }

    func testTheMostRecentPlayWinsNotTheFurthestAndNotTheLastToUpload() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        try playRecord(&a, item: "ep-1", ms: 600_000, at: t0 + 1000)
        try playRecord(&b, item: "ep-1", ms: 120_000, cause: .seek, at: t0 + 2000)   // a deliberate rewind, later
        b.syncNow(with: &cloud, nowMillis: t0 + 2100)
        a.syncNow(with: &cloud, nowMillis: t0 + 9000)                               // A's old place reaches the cloud last
        b.syncNow(with: &cloud, nowMillis: t0 + 9100)
        for replica in [a, b] {
            let place = try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(replica.record(.place("ep-1")))))
            XCTAssertEqual(place.position, .number(120_000), "the rewind is the most recent play, though it is not the furthest")
            XCTAssertEqual(place.cause, .seek)
        }
    }

    func testCompletionIsStickyWithinOneRevisionAndEndsWhenTheListenerPlaysAgain() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        try playRecord(&a, item: "ep-1", ms: 3_500_000, at: t0 + 1000)
        try a.edit(.place("ep-1")) { record, clock in ListeningPlaceSync.recordCompletion(sourceRevision: "rev-1", in: &record, clock: &clock, atMillis: t0 + 2000) }
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertTrue(try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(b.record(.place("ep-1"))))).isCompleted)
        try playRecord(&b, item: "ep-1", ms: 10_000, at: t0 + 4000)    // started it again
        syncBoth(&a, &b, &cloud, at: t0 + 5000)
        XCTAssertFalse(try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(a.record(.place("ep-1"))))).isCompleted)
        // Finished in one revision does not finish another.
        try a.edit(.place("ep-1")) { record, clock in ListeningPlaceSync.recordCompletion(sourceRevision: "rev-OLD", in: &record, clock: &clock, atMillis: t0 + 6000) }
        XCTAssertFalse(try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(a.record(.place("ep-1"))))).isCompleted)
    }

    func testAFinishOnAPhoneWithAClockBehindStillCountsAfterThePlayItHadSeen() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        try playRecord(&a, item: "ep-1", ms: 3_500_000, at: t0 + 1000)
        syncBoth(&a, &b, &cloud, at: t0 + 1500)
        // B finishes the episode with its clock a year behind. Its finish is after the play it had received.
        try b.edit(.place("ep-1")) { record, clock in ListeningPlaceSync.recordCompletion(sourceRevision: "rev-1", in: &record, clock: &clock, atMillis: t0 - 365 * day) }
        syncBoth(&a, &b, &cloud, at: t0 + 3000)
        XCTAssertTrue(try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(a.record(.place("ep-1"))))).isCompleted)
    }

    func testFinishingTheSameRevisionTwiceReachesTheOtherPhoneBothTimes() throws {
        var a = SyncReplica(device: "A")
        var b = SyncReplica(device: "B")
        var cloud = SyncTestCloud()
        try playRecord(&a, item: "ep-1", ms: 3_500_000, at: t0 + 1000)
        try a.edit(.place("ep-1")) { record, clock in ListeningPlaceSync.recordCompletion(sourceRevision: "rev-1", in: &record, clock: &clock, atMillis: t0 + 2000) }
        syncBoth(&a, &b, &cloud, at: t0 + 2500)
        try playRecord(&a, item: "ep-1", ms: 0, at: t0 + 3000)                       // listens again from the start
        syncBoth(&a, &b, &cloud, at: t0 + 3500)
        XCTAssertFalse(try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(b.record(.place("ep-1"))))).isCompleted)
        try playRecord(&a, item: "ep-1", ms: 3_500_000, at: t0 + 4000)
        try a.edit(.place("ep-1")) { record, clock in ListeningPlaceSync.recordCompletion(sourceRevision: "rev-1", in: &record, clock: &clock, atMillis: t0 + 5000) }
        syncBoth(&a, &b, &cloud, at: t0 + 5500)
        XCTAssertTrue(try XCTUnwrap(ListeningPlaceSync.place(of: try XCTUnwrap(b.record(.place("ep-1"))))).isCompleted, "the second finish is a new event")
    }

    func testADeleteMadeOfflineIsKeptNinetyDaysFromWhenTheCloudGotItAndAnUnpushedDeleteIsNeverForgotten() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        // A deletes on day 0 and stays offline. B last synced on day 80. A pushes on day 85.
        try a.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0) }
        a.compactTombstones(nowMillis: t0 + 100 * day)
        XCTAssertNotNil(a.record(marginID), "an expired delete the cloud has not confirmed is not forgotten")
        b.syncNow(with: &cloud, nowMillis: t0 + 80 * day)
        a.syncNow(with: &cloud, nowMillis: t0 + 85 * day)
        cloud.compactTombstones(nowMillis: t0 + 91 * day)
        XCTAssertNotNil(cloud.records[marginID], "6 days after the cloud received it")
        b.syncNow(with: &cloud, nowMillis: t0 + 91 * day)
        XCTAssertTrue(try XCTUnwrap(b.record(marginID)).isDeleted, "B gets the delete")
        cloud.compactTombstones(nowMillis: t0 + 176 * day)
        XCTAssertNil(cloud.records[marginID])
        var sleeper = SyncReplica(device: "C")
        sleeper.receive(b.records.values.map { $0 })
        sleeper.pullCompleted(since: 0, upTo: 0, nowMillis: t0 + 80 * day)
        XCTAssertTrue(cloud.pull(since: 0, lastSyncedMillis: sleeper.lastSyncedMillis).resync, "a phone that last synced before the cloud got the delete starts over")
    }

    func testAResponseThatOutlivedAReinstallDoesNotMakeTheNewInstallThinkItIsCaughtUp() throws {
        var (a, _, cloud) = try twoPhonesWithOneMargin()
        try set(&a, .margin("m2"), "displayText", "second", at: t0 + 1000)
        a.syncNow(with: &cloud, nowMillis: t0 + 1000)
        let late = cloud.pull(since: 1, lastSyncedMillis: nil)     // asked for by the old install, from change 1 on
        var fresh = SyncReplica(device: "A-new-install")
        fresh.receive(late.records)
        fresh.pullCompleted(since: late.since, upTo: late.token, nowMillis: t0 + 2000)
        XCTAssertEqual(fresh.pullToken, 0, "it has not received the changes before 1")
        XCTAssertNil(fresh.lastSyncedMillis)
        fresh.syncNow(with: &cloud, nowMillis: t0 + 3000)
        XCTAssertEqual(fresh.records, cloud.records)
    }

    func testWhatADeviceDoesWithAPlaceThatArrived() {
        func stamp(_ wall: Int64) -> SyncStamp { SyncStamp(wallMillis: wall, counter: 0, device: "B") }
        func place(_ wall: Int64, revision: String = "rev-1", completedAt: Int64? = nil) -> ListeningPlaceSync.Place {
            .init(position: .number(5), sourceRevision: revision, stamp: stamp(wall), cause: .play, completedAt: completedAt.map(stamp))
        }
        let local = ListeningPlaceSync.LocalPlace(sourceRevision: "rev-1", lastPlayedAt: stamp(100))
        let decide = ListeningPlaceSync.decide

        XCTAssertEqual(decide(place(200), local, false), .adopt(place(200)), "a newer place on the same recording")
        XCTAssertEqual(decide(place(200), local, true), .deferUntilStopped(place(200)), "a playing device is never moved")
        XCTAssertEqual(decide(place(50), local, false), .keepLocal, "this device played more recently")
        XCTAssertEqual(decide(place(100), local, false), .keepLocal, "the same moment")
        XCTAssertEqual(decide(place(200, revision: "rev-2"), local, false), .offer(place(200, revision: "rev-2")), "a re-cut or edited source is not applied")
        XCTAssertEqual(decide(place(200, revision: "rev-2"), local, true), .offer(place(200, revision: "rev-2")), "and a playing device is not moved by it either")
        XCTAssertEqual(decide(place(200), .init(sourceRevision: "rev-1", lastPlayedAt: nil), false), .adopt(place(200)), "a device that never played")
        XCTAssertEqual(decide(place(50, completedAt: 150), local, false), .markCompleted, "finished elsewhere after this device last played")
        XCTAssertEqual(decide(place(50, completedAt: 80), local, false), .keepLocal, "finished before this device played again")
        XCTAssertEqual(decide(place(50, revision: "rev-2", completedAt: 150), local, false), .keepLocal, "finished a different recording")
        XCTAssertEqual(decide(place(200, completedAt: 250), local, true), .deferUntilStopped(place(200, completedAt: 250)))
    }

    // MARK: - Tombstones and the 90-day return

    func testADeleteMarkerIsKeptNinetyDaysThenForgotten() throws {
        var (a, _, cloud) = try twoPhonesWithOneMargin()
        try a.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0) }
        a.syncNow(with: &cloud, nowMillis: t0)      // the cloud has the delete, so nothing is owed
        a.compactTombstones(nowMillis: t0 + 89 * day)
        XCTAssertNotNil(a.record(marginID), "still kept at 89 days")
        a.compactTombstones(nowMillis: t0 + 91 * day)
        XCTAssertNil(a.record(marginID), "forgotten after 90")
        // An active record is never forgotten, however old.
        var other = SyncReplica(device: "A")
        try set(&other, .margin("m2"), "displayText", "kept", at: t0)
        other.compactTombstones(nowMillis: t0 + 900 * day)
        XCTAssertNotNil(other.record(.margin("m2")))
    }

    func testAPhoneBackWithinNinetyDaysGetsTheDeleteAndAPhoneBackAfterwardsKeepsItsOwnData() throws {
        var (a, b, cloud) = try twoPhonesWithOneMargin()
        // B goes away, with a Margin of its own not yet uploaded.
        try b.edit(.margin("m-b")) { record, clock in
            record = try! MarginSync.record(for: SyncFixtures.margin(id: "m-b", text: "written offline"), itemKey: "ep-2", clock: &clock, wallMillis: self.t0 + day)
        }
        try a.edit(marginID) { record, clock in record.markDeleted(clock: &clock, wallMillis: self.t0 + 2 * day) }
        a.syncNow(with: &cloud, nowMillis: t0 + 2 * day)

        var early = b
        var earlyCloud = cloud
        early.syncNow(with: &earlyCloud, nowMillis: t0 + 50 * day)
        XCTAssertTrue(try XCTUnwrap(early.record(marginID)).isDeleted, "back inside 90 days: the delete arrives")

        cloud.compactTombstones(nowMillis: t0 + 100 * day)
        XCTAssertNil(cloud.records[marginID], "the cloud forgot the marker")
        XCTAssertTrue(cloud.pull(since: 0, lastSyncedMillis: t0).resync, "B last synced before the floor: it is told to start over")
        a.compactTombstones(nowMillis: t0 + 100 * day)
        syncBoth(&a, &b, &cloud, at: t0 + 100 * day)
        XCTAssertNotNil(cloud.records[.margin("m-b")], "B's own Margin is kept and uploaded")
        XCTAssertNotNil(a.record(.margin("m-b")))
        XCTAssertEqual(b.record(.margin("m-b"))?["displayText"]?.stringValue, "written offline")
        // The marker is gone, so B's old copy of the deleted Margin comes back. That is the safe failure: nothing is lost.
        XCTAssertFalse(try XCTUnwrap(cloud.records[marginID]).isDeleted)
        XCTAssertEqual(a.records, b.records)
    }

    // MARK: - A build that reads less

    func testARecordFromANewerReadingIsParkedNotEditedAndKeptWhole() throws {
        var old = SyncReplica(device: "OLD", supportedSchemaVersion: 1)
        var newClock = SyncClock(device: "NEW")
        var future = SyncRecord(id: .item("clip-1"), schemaVersion: 2)
        future.set("body", .string("something new"), clock: &newClock, wallMillis: t0)
        old.receive([future])
        XCTAssertEqual(old.parkedRecordCount, 1)
        XCTAssertTrue(old.readableRecords.isEmpty)
        XCTAssertThrowsError(try set(&old, .item("clip-1"), "body", "overwritten", at: t0 + 1))
        XCTAssertEqual(old.record(.item("clip-1")), future, "kept untouched, so a later build can read it")
    }

    func testAnOlderBuildEditingAMarginKeepsFieldsItDoesNotKnow() throws {
        var current = SyncReplica(device: "NEW", supportedSchemaVersion: 2)
        var old = SyncReplica(device: "OLD", supportedSchemaVersion: 1)
        var cloud = SyncTestCloud()
        try current.edit(marginID) { record, clock in
            record = try! MarginSync.record(for: SyncFixtures.margin(id: "m1"), itemKey: "ep-1", clock: &clock, wallMillis: self.t0)
            record.set("reaction", .string("heart"), clock: &clock, wallMillis: self.t0)
        }
        syncBoth(&current, &old, &cloud, at: t0)
        try set(&old, marginID, "displayText", "edited on the old build", at: t0 + 1000)
        syncBoth(&current, &old, &cloud, at: t0 + 2000)
        for replica in [current, old] {
            XCTAssertEqual(replica.record(marginID)?["reaction"]?.stringValue, "heart")
            XCTAssertEqual(replica.record(marginID)?["displayText"]?.stringValue, "edited on the old build")
        }
    }

    // MARK: - Reinstall, restore and acknowledgements

    func testAPhoneRestoredFromAnOlderBackupDoesNotRollTheCloudBack() throws {
        var (a, _, cloud) = try twoPhonesWithOneMargin()
        let backup = a
        try set(&a, marginID, "displayText", "edited after the backup", at: t0 + 1000)
        a.syncNow(with: &cloud, nowMillis: t0 + 1000)
        a = backup
        a.syncNow(with: &cloud, nowMillis: t0 + 2000)
        XCTAssertEqual(a.record(marginID)?["displayText"]?.stringValue, "edited after the backup")
        XCTAssertEqual(cloud.records[marginID]?["displayText"]?.stringValue, "edited after the backup")
        try set(&a, marginID, "displayText", "edited again", at: t0 + 2500)
        a.syncNow(with: &cloud, nowMillis: t0 + 3000)
        XCTAssertEqual(cloud.records[marginID]?["displayText"]?.stringValue, "edited again", "its clock is above its own earlier stamps")
    }

    func testAnOldConfirmationNeverDropsANewerEdit() throws {
        var a = SyncReplica(device: "A")
        try set(&a, marginID, "displayText", "one", at: t0)
        let sent = a.outbox
        try set(&a, marginID, "displayText", "two", at: t0 + 1000)
        a.acknowledge(sent)
        XCTAssertEqual(a.outbox.count, 1, "the newer edit is still owed")
        let sentAgain = a.outbox
        a.acknowledge(sentAgain)
        XCTAssertTrue(a.outbox.isEmpty)
    }

    func testAReinstalledPhoneGetsEverythingBackFromTheCloud() throws {
        var (a, _, cloud) = try twoPhonesWithOneMargin()
        try set(&a, marginID, "displayText", "words", at: t0 + 1000)
        a.syncNow(with: &cloud, nowMillis: t0 + 1000)
        var fresh = SyncReplica(device: "A-new-install")
        fresh.syncNow(with: &cloud, nowMillis: t0 + 2000)
        XCTAssertEqual(fresh.record(marginID)?["displayText"]?.stringValue, "words")
        XCTAssertEqual(fresh.records, cloud.records)
    }
}
