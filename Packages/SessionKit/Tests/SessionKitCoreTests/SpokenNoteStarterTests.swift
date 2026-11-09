import XCTest
@testable import SessionKit

/// #3108, one-tap start: a new note is a folder with an empty `note.json` and a Library item, made on real files.
final class SpokenNoteStarterTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-starter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    func testStartMakesTheFolderTheFileAndTheItem() throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 50), makeId: { "n1" })
        XCTAssertEqual(started.note.id, "n1")
        XCTAssertTrue(started.note.isEmpty)
        XCTAssertEqual(started.store.folderURL.path, support.appendingPathComponent("SpokenNotes/n1").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.store.fileURL.path), "the note is on disk before any take")
        XCTAssertEqual(started.store.load(), started.note)
        XCTAssertEqual(started.item.id, "spoken-note-n1")
        XCTAssertEqual(started.item.mediaType, "spoken_note")
        XCTAssertEqual(started.item.externalReference, "note://n1")
        XCTAssertEqual(started.item.createdAt, Date(timeIntervalSince1970: 50))
    }

    func testTwoStartsMakeTwoNotesWithOwnFolders() throws {
        let a = try SpokenNoteStarter.start(in: support, now: Date())
        let b = try SpokenNoteStarter.start(in: support, now: Date())
        XCTAssertNotEqual(a.note.id, b.note.id)
        XCTAssertNotEqual(a.store.folderURL, b.store.folderURL)
        XCTAssertNotEqual(a.item.id, b.item.id)
    }

    func testAnExistingNoteIsNeverOverwrittenByAStart() throws {
        let first = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { "n1" })
        var note = first.note
        note.appendTake(SpokenNoteTake(id: "t1", audioFileName: "t1.m4a", durationMs: 1000, createdAt: Date(timeIntervalSince1970: 0),
                                       sentences: [SpokenNoteSentence(text: "Keep me.", startMs: 0, endMs: 900)]))
        try first.store.save(note)

        // The id source offers the taken id first, then a free one: the taken note stays as it was.
        var offered = ["n1", "n2"]
        let second = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { offered.removeFirst() })
        XCTAssertEqual(second.note.id, "n2")
        XCTAssertEqual(first.store.load().text, "Keep me.")

        XCTAssertThrowsError(try SpokenNoteStarter.start(in: support, now: Date(), makeId: { "n1" })) {
            XCTAssertEqual($0 as? SpokenNoteStarter.StartError, .noFreeNoteId)
        }
        XCTAssertEqual(first.store.load().text, "Keep me.")
    }

    func testAnItemFindsItsNoteFolderAndOnlyThatFolder() throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { "n1" })
        XCTAssertEqual(SpokenNoteStarter.store(for: started.item, in: support)?.folderURL, started.store.folderURL)
        let text = Item(id: "i", title: "T", mediaType: "text", text: "x", externalReference: "note://n1", status: "ready")
        XCTAssertNil(SpokenNoteStarter.store(for: text, in: support), "only a spoken note item names a note")
    }

    /// An item's reference comes back from the database or a packet, so it can't name a path outside the notes folder.
    func testUnsafeNoteIdsNameNoFolder() {
        for id in ["", ".", "..", "../x", "a/b", "/abs", "a\\b", "a\0b", "N1", "caf\u{E9}", String(repeating: "a", count: 101)] {
            XCTAssertNil(SpokenNoteStarter.store(noteId: id, in: support), "\(id.debugDescription) must not be a folder")
        }
        let escaping = Item(id: "i", title: "T", mediaType: "spoken_note", text: "", externalReference: "note://../../x", status: "ready")
        XCTAssertNil(SpokenNoteStarter.store(for: escaping, in: support))
        XCTAssertNotNil(SpokenNoteStarter.store(noteId: "3f2a-9c", in: support))
    }

    func testAnUnsafeIdFromTheSourceIsSkippedNotUsed() throws {
        var offered = ["../evil", "ok"]
        let started = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { offered.removeFirst() })
        XCTAssertEqual(started.note.id, "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("evil").path))
    }

    /// A folder that is already there, with or without a `note.json` in it, is never reused.
    func testAFolderWithoutANoteFileIsSkippedToo() throws {
        let stale = support.appendingPathComponent("SpokenNotes/stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        var offered = ["stale", "fresh"]
        let started = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { offered.removeFirst() })
        XCTAssertEqual(started.note.id, "fresh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.appendingPathComponent("note.json").path))
    }

    func testIdsAnOlderBuildOrAUUIDWouldMakeAreSafe() {
        XCTAssertNotNil(SpokenNoteStarter.store(noteId: UUID().uuidString.lowercased(), in: support))
        XCTAssertNotNil(SpokenNoteStarter.store(noteId: "note_1-a", in: support))
    }

    // MARK: Reopening a note from its Library row

    func testReopenReturnsTheNoteAsSavedWithTheRowsTitleAndWritesNothing() throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try Data([1]).write(to: started.store.folderURL.appendingPathComponent("take-a.m4a"))
        try SpokenNoteIntake.addRecordedTake(audioFileName: "take-a.m4a", durationMs: 2_000, to: started.store, now: Date(timeIntervalSince1970: 2), takeId: "a")
        let before = try Data(contentsOf: started.store.fileURL)

        let reopened = SpokenNoteStarter.reopen(noteId: "n1", title: "Plumber call", in: support, now: Date(timeIntervalSince1970: 9))

        XCTAssertEqual(reopened?.note.takes.map(\.id), ["a"])
        XCTAssertEqual(reopened?.item.id, "spoken-note-n1", "the same row the note was saved under")
        XCTAssertEqual(reopened?.item.title, "Plumber call")
        XCTAssertEqual(try Data(contentsOf: started.store.fileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.store.itemSavedMarkerURL.path), "reopening alone records nothing")
    }

    func testReopenOfAMissingOrUnsafeNoteIsNilAndCreatesNothing() throws {
        XCTAssertNil(SpokenNoteStarter.reopen(noteId: "gone", title: nil, in: support, now: Date()))
        XCTAssertNil(SpokenNoteStarter.reopen(noteId: "../escape", title: nil, in: support, now: Date()))
        XCTAssertNil(SpokenNoteStarter.reopen(noteId: "", title: nil, in: support, now: Date()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SpokenNoteStarter.notesRoot(in: support).appendingPathComponent("gone").path))
    }

    func testReopenOfAFolderWithAnUnreadableNoteFileIsAnEmptyNoteNotACrash() throws {
        let started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
        try Data("not json".utf8).write(to: started.store.fileURL)
        let reopened = SpokenNoteStarter.reopen(noteId: "n1", title: nil, in: support, now: Date())
        XCTAssertEqual(reopened?.note.isEmpty, true)
        XCTAssertEqual(reopened?.item.title, SpokenNoteTitle.automatic(createdAt: reopened?.item.createdAt, text: ""))
    }

    func testARowOpensAsANoteOnlyWhenItIsOne() {
        func row(_ type: String, _ reference: String?) -> LibraryItemRow {
            LibraryItemRow(id: "i", title: "T", status: "s", canDelete: true, mediaType: type, sourceReference: reference)
        }
        XCTAssertEqual(row("spoken_note", "note://n1").spokenNoteId, "n1")
        XCTAssertEqual(row("Spoken_Note", "note://n1").spokenNoteId, "n1", "case does not matter")
        XCTAssertNil(row("text", "note://n1").spokenNoteId, "an ordinary item that happens to carry the reference")
        XCTAssertNil(row("spoken_note", nil).spokenNoteId)
        XCTAssertNil(row("spoken_note", "note://").spokenNoteId)
        XCTAssertNil(row("spoken_note", "https://example.com/n1").spokenNoteId)
    }
}
