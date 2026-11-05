import Foundation
import XCTest
@testable import SessionKit

/// #3108, from the audit of #3388: a late transcript must not undo what the listener did to the note's row, and
/// dictation cut off by an ended app must be found again. Real temporary folders.
final class SpokenNoteRecoveryAndMergeTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-rec2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    private func row(text: String? = "", deletedAt: Date? = nil, title: String = "Spoken note") -> Item {
        var item = Item(id: "spoken-note-n1", title: title, mediaType: "spoken_note", text: text, externalReference: "note://n1", status: "ready")
        item.deletedAt = deletedAt
        return item
    }

    // MARK: Merge

    func testOnlyTheTextOfAnExistingRowChanges() {
        let stored = row(text: "", title: "Plumber call")
        let saved = SpokenNoteItemMerge.rowToSave(stored: stored, incoming: row(text: "Call the plumber."), isFirstSave: false)
        XCTAssertEqual(saved?.text, "Call the plumber.")
        XCTAssertEqual(saved?.title, "Plumber call", "a rename survives the transcript")
    }

    func testATrashedRowStaysTrashed() {
        let stored = row(text: "", deletedAt: Date(timeIntervalSince1970: 9))
        XCTAssertNil(SpokenNoteItemMerge.rowToSave(stored: stored, incoming: row(text: "Call the plumber."), isFirstSave: false))
    }

    func testARowThatIsGoneIsNotMadeAgainAfterItsFirstSave() {
        XCTAssertNil(SpokenNoteItemMerge.rowToSave(stored: nil, incoming: row(text: "x"), isFirstSave: false))
        XCTAssertEqual(SpokenNoteItemMerge.rowToSave(stored: nil, incoming: row(text: "x"), isFirstSave: true)?.id, "spoken-note-n1")
    }

    func testUnchangedTextWritesNothing() {
        XCTAssertNil(SpokenNoteItemMerge.rowToSave(stored: row(text: "same"), incoming: row(text: "same"), isFirstSave: false))
    }

    /// The audit's scenario end to end: the row is trashed while the transcript is still being made.
    func testATranscriptThatArrivesAfterTheNoteWasTrashedDoesNotBringItBack() async throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        let database = FakeDatabase()
        let transcriber = GatedTranscriber()
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store, item: started.item, itemIsSaved: false,
            recorder: WritingRecorder(), transcriber: transcriber, itemWriter: database,
            now: { Date(timeIntervalSince1970: 5) }, makeTakeId: { "t1" }
        )
        try await coordinator.startTake()
        try await coordinator.stopTake()
        XCTAssertEqual(database.row(started.item.id)?.text, "", "the row exists after the first take")

        database.trash(started.item.id)
        transcriber.release()
        await coordinator.waitForTranscripts()

        XCTAssertNotNil(database.row(started.item.id)?.deletedAt, "still in the trash")
        XCTAssertEqual(database.row(started.item.id)?.text, "", "the deleted row was not rewritten")
        XCTAssertEqual(started.store.load().takes[0].sentences.map(\.text), ["Call the plumber."], "the note itself still has its transcript")

        database.remove(started.item.id) // emptied from the trash
        await coordinator.flushItem()
        XCTAssertNil(database.row(started.item.id), "a permanently deleted row is not made again")
    }

    // MARK: Recovery

    private func writeTake(_ noteId: String, _ name: String, age: TimeInterval) throws {
        let folder = SpokenNoteStarter.notesRoot(in: support).appendingPathComponent(noteId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10_000 - age)], ofItemAtPath: url.path)
    }

    func testAnAudioFileNoNoteListsIsAddedWithItsRowAndNothingIsRemoved() throws {
        // The app was ended during the note's first take: a folder with note.json and audio, and no row.
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try writeTake("n1", "take-abc.m4a", age: 600)
        let database = FakeDatabase()

        let recovered = SpokenNoteRecovery.recover(
            in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 7_000 }, itemWriter: database, liveNoteIds: []
        )

        XCTAssertEqual(recovered, ["n1"])
        let take = started.store.load().takes.first
        XCTAssertEqual(take?.id, "abc")
        XCTAssertEqual(take?.audioFileName, "take-abc.m4a")
        XCTAssertEqual(take?.durationMs, 7_000)
        XCTAssertNotNil(database.row(started.item.id), "the Library row exists, so the note can be reached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.store.folderURL.appendingPathComponent("take-abc.m4a").path))
    }

    func testAFreshFileIsRecoveredAtOnceAndRunningTwiceDoesNotDoubleIt() throws {
        // Reopening the app within a minute of a crash must still find the dictation: no time window.
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try writeTake("n1", "take-fresh.m4a", age: 5)
        let database = FakeDatabase()
        let now = Date(timeIntervalSince1970: 10_000)

        let first = SpokenNoteRecovery.recover(in: support, now: now, measureDurationMs: { _ in 0 }, itemWriter: database, liveNoteIds: [])
        let again = SpokenNoteRecovery.recover(in: support, now: now, measureDurationMs: { _ in 0 }, itemWriter: database, liveNoteIds: [])

        XCTAssertEqual(first, ["n1"])
        XCTAssertEqual(started.store.load().takes.map(\.id), ["fresh"])
        XCTAssertEqual(again, [], "nothing new the second time")
    }

    func testANoteWithARecorderOpenInThisProcessIsLeftAlone() async throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store, item: started.item, itemIsSaved: false,
            recorder: WritingRecorder(), transcriber: GatedTranscriber(), itemWriter: FakeDatabase()
        )
        try await coordinator.startTake() // writes take-<uuid>.m4a, not yet in the note
        XCTAssertTrue(SpokenNoteLiveNotes.ids().contains("n1"))

        let recovered = SpokenNoteRecovery.recover(in: support, now: Date(), measureDurationMs: { _ in 0 }, itemWriter: FakeDatabase())
        XCTAssertEqual(recovered, [], "the file being recorded is not adopted by recovery")
        XCTAssertTrue(started.store.load().takes.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    func testARowTheListenerDeletedIsNotMadeAgainWhenALaterTakeIsRecovered() throws {
        // The note already had a take (and so a row); the row was trashed and emptied from the trash; take 2 was cut off.
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try Data([1]).write(to: started.store.folderURL.appendingPathComponent("take-one.m4a"))
        try SpokenNoteIntake.addRecordedTake(audioFileName: "take-one.m4a", durationMs: 1_000, to: started.store, now: Date(timeIntervalSince1970: 2), takeId: "one")
        started.store.markItemSaved() // the row was written when take 1 was added
        try writeTake("n1", "take-two.m4a", age: 600)
        let database = FakeDatabase() // no row: it was deleted for good

        SpokenNoteRecovery.recover(in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: database, liveNoteIds: [])

        XCTAssertEqual(started.store.load().takes.map(\.id), ["one", "two"], "the audio is still added to the note")
        XCTAssertNil(database.row(started.item.id), "but the deleted row is not made again")
    }

    /// The audit's second finding: the first row save failed, the app ended during a later take, and the note had no
    /// row for good. The row was never written, so recovery makes it.
    func testARowThatWasNeverSavedIsMadeWhenALaterTakeIsRecovered() async throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        let failing = FailingDatabase()
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store, item: started.item, itemIsSaved: false,
            recorder: WritingRecorder(), transcriber: GatedTranscriber(), itemWriter: failing,
            now: { Date(timeIntervalSince1970: 5) }, makeTakeId: { "t1" }
        )
        try await coordinator.startTake()
        try await coordinator.stopTake() // take 1 is in the note; its row save failed
        XCTAssertFalse(started.store.itemWasSaved)
        try writeTake("n1", "take-two.m4a", age: 600) // the app ended during take 2
        let database = FakeDatabase()

        let recovered = SpokenNoteRecovery.recover(
            in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: database, liveNoteIds: []
        )

        XCTAssertEqual(recovered, ["n1"])
        XCTAssertEqual(started.store.load().takes.map(\.id), ["t1", "two"])
        XCTAssertNotNil(database.row(started.item.id), "the note can be reached from the Library")
        XCTAssertTrue(started.store.itemWasSaved)
    }

    func testARowThatWasSavedThenDeletedStaysDeletedWhenALaterTakeIsRecovered() async throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        let database = FakeDatabase()
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store, item: started.item, itemIsSaved: false,
            recorder: WritingRecorder(), transcriber: GatedTranscriber(), itemWriter: database,
            now: { Date(timeIntervalSince1970: 5) }, makeTakeId: { "t1" }
        )
        try await coordinator.startTake()
        try await coordinator.stopTake()
        XCTAssertTrue(started.store.itemWasSaved)
        database.remove(started.item.id) // trashed and emptied
        try writeTake("n1", "take-two.m4a", age: 600)

        SpokenNoteRecovery.recover(in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: database, liveNoteIds: [])

        XCTAssertEqual(started.store.load().takes.map(\.id), ["t1", "two"], "the dictation is still reachable in its folder")
        XCTAssertNil(database.row(started.item.id), "the deleted row is not made again")
    }

    func testARowThatFailsToSaveDuringRecoveryIsOfferedAgainNextLaunch() throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try writeTake("n1", "take-a.m4a", age: 600)
        SpokenNoteRecovery.recover(in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: FailingDatabase(), liveNoteIds: [])
        XCTAssertFalse(started.store.itemWasSaved, "no marker for a row that was not written")

        let database = FakeDatabase()
        try writeTake("n1", "take-b.m4a", age: 600) // anything new brings the note back into recovery
        SpokenNoteRecovery.recover(in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: database, liveNoteIds: [])
        XCTAssertNotNil(database.row(started.item.id))
    }

    func testRecoveryLeavesAnUnreadableNoteAloneAndKeepsAFileThatWillNotOpen() throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try writeTake("n1", "take-cut.m4a", age: 600)
        // A file that will not open is still added (no length), so it is kept and listed.
        SpokenNoteRecovery.recover(in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: FakeDatabase(), liveNoteIds: [])
        XCTAssertEqual(started.store.load().takes.first?.durationMs, 0)

        // note.json that cannot be read: nothing is added or written over.
        let second = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n2" })
        try writeTake("n2", "take-z.m4a", age: 600)
        try FileManager.default.removeItem(at: second.store.fileURL)
        try FileManager.default.createDirectory(at: second.store.fileURL, withIntermediateDirectories: false)
        let recovered = SpokenNoteRecovery.recover(in: support, now: Date(timeIntervalSince1970: 10_000), measureDurationMs: { _ in 0 }, itemWriter: FakeDatabase(), liveNoteIds: [])
        XCTAssertFalse(recovered.contains("n2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.store.folderURL.appendingPathComponent("take-z.m4a").path))
    }
}

// MARK: Stand-ins

/// A database that applies `SpokenNoteItemMerge` as the app's store does.
private final class FakeDatabase: SpokenNoteItemWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: Item] = [:]

    func write(_ item: Item, isFirstSave: Bool) throws {
        lock.withLock {
            if let toSave = SpokenNoteItemMerge.rowToSave(stored: rows[item.id], incoming: item, isFirstSave: isFirstSave) {
                rows[item.id] = toSave
            }
        }
    }

    func row(_ id: String) -> Item? { lock.withLock { rows[id] } }
    func trash(_ id: String) { lock.withLock { rows[id]?.deletedAt = Date(timeIntervalSince1970: 99) } }
    func remove(_ id: String) { lock.withLock { rows[id] = nil } }
}

private final class FailingDatabase: SpokenNoteItemWriting, @unchecked Sendable {
    func write(_ item: Item, isFirstSave: Bool) throws { throw NSError(domain: "db", code: 1) }
}

private final class WritingRecorder: SpokenNoteTakeRecording, @unchecked Sendable {
    func begin(writingTo url: URL) async throws { try Data([1]).write(to: url) }
    func end() async throws -> Int { 2_000 }
    func setStoppedBySystemHandler(_ handler: (@Sendable () -> Void)?) {}
}

private final class GatedTranscriber: SpokenNoteTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment] {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return [
            AlignedTranscriptSegment(id: "w0", text: "Call", startMs: 0, endMs: 300),
            AlignedTranscriptSegment(id: "w1", text: "the", startMs: 400, endMs: 600),
            AlignedTranscriptSegment(id: "w2", text: "plumber.", startMs: 700, endMs: 1_200)
        ]
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}
