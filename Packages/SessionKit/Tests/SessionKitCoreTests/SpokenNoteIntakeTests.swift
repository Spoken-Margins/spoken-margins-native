import Foundation
import XCTest
@testable import SessionKit

/// #3108: a finished recording becomes a take the moment its audio is on disk, and the transcript fills in later.
/// Real temporary files throughout.
final class SpokenNoteIntakeTests: XCTestCase {
    private var support: URL!
    private var started: SpokenNoteStarter.Started!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    private func writeAudio(_ name: String) throws {
        try Data([0, 1, 2]).write(to: started.store.folderURL.appendingPathComponent(name))
    }

    private func words(_ texts: [String]) -> [AlignedTranscriptSegment] {
        texts.enumerated().map { AlignedTranscriptSegment(id: "w\($0.offset)", text: $0.element, startMs: $0.offset * 400, endMs: $0.offset * 400 + 300) }
    }

    func testARecordedTakeIsSavedWithoutATranscriptAndSurvivesAReload() throws {
        try writeAudio("take-1.m4a")
        let note = try SpokenNoteIntake.addRecordedTake(audioFileName: "take-1.m4a", durationMs: 5_000, to: started.store, now: Date(timeIntervalSince1970: 9), takeId: "t1")
        XCTAssertEqual(note.takes.map(\.id), ["t1"])
        XCTAssertFalse(note.takes[0].hasTranscript, "the transcriber has not run yet")
        XCTAssertEqual(started.store.load(), note, "what is on disk is what came back")
        XCTAssertEqual(started.store.load().takes[0].audioFileName, "take-1.m4a")
    }

    func testTakesAppendInOrderAndARepeatedSaveDoesNotDoubleATake() throws {
        try writeAudio("a.m4a"); try writeAudio("b.m4a")
        try SpokenNoteIntake.addRecordedTake(audioFileName: "a.m4a", durationMs: 1, to: started.store, now: Date(), takeId: "t1")
        try SpokenNoteIntake.addRecordedTake(audioFileName: "b.m4a", durationMs: 2, to: started.store, now: Date(), takeId: "t2")
        let again = try SpokenNoteIntake.addRecordedTake(audioFileName: "b.m4a", durationMs: 2, to: started.store, now: Date(), takeId: "t2")
        XCTAssertEqual(again.takes.map(\.id), ["t1", "t2"])
        XCTAssertEqual(started.store.load().takes.map(\.audioFileName), ["a.m4a", "b.m4a"])
    }

    func testATakeNeedsItsAudioOnDiskInThisNotesFolder() throws {
        XCTAssertThrowsError(try SpokenNoteIntake.addRecordedTake(audioFileName: "nope.m4a", durationMs: 1, to: started.store, now: Date())) {
            XCTAssertEqual($0 as? SpokenNoteIntake.IntakeError, .audioFileMissing)
        }
        XCTAssertTrue(started.store.load().isEmpty, "a refused take leaves the note as it was")
        let gone = SpokenNoteStore(folderURL: support.appendingPathComponent("SpokenNotes/none"), noteId: "none")
        XCTAssertThrowsError(try SpokenNoteIntake.addRecordedTake(audioFileName: "x.m4a", durationMs: 1, to: gone, now: Date())) {
            XCTAssertEqual($0 as? SpokenNoteIntake.IntakeError, .noteNotFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.folderURL.path), "intake never creates a note folder")
    }

    func testAudioFileNamesThatLeaveTheFolderOrNameTheNoteFileAreRefused() throws {
        try Data([1]).write(to: support.appendingPathComponent("outside.m4a"))
        for name in ["", ".", "..", "../outside.m4a", "a/b.m4a", "a\\b.m4a", "note.json", "NOTE.JSON", "note.unreadable.json", "a\nb.m4a", "note.jſon", "née.m4a"] {
            XCTAssertThrowsError(try SpokenNoteIntake.addRecordedTake(audioFileName: name, durationMs: 1, to: started.store, now: Date()), name) {
                XCTAssertEqual($0 as? SpokenNoteIntake.IntakeError, .unsafeAudioFileName, name)
            }
        }
        XCTAssertTrue(started.store.load().isEmpty)
        for name in ["take 1.m4a", "Take.M4A", "notes.m4a", "note.m4a"] {
            XCTAssertTrue(SpokenNoteIntake.isPlainFileName(name), name)
        }
    }

    func testAudioThatIsAFolderOrALinkIsNotATake() throws {
        let folder = started.store.folderURL
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.m4a"), withIntermediateDirectories: false)
        let target = support.appendingPathComponent("elsewhere.m4a")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.m4a"), withDestinationURL: target)
        for name in ["dir.m4a", "link.m4a"] {
            XCTAssertThrowsError(try SpokenNoteIntake.addRecordedTake(audioFileName: name, durationMs: 1, to: started.store, now: Date()), name) {
                XCTAssertEqual($0 as? SpokenNoteIntake.IntakeError, .audioFileMissing, name)
            }
        }
    }

    /// A note file that is there but can't be read must not become an empty note that the next save writes over.
    /// (Here `note.json` is a folder, which cannot be read as a file; a locked phone fails the same way.)
    func testANoteThatCannotBeReadIsNeverSavedOver() throws {
        try writeAudio("a.m4a")
        try SpokenNoteIntake.addRecordedTake(audioFileName: "a.m4a", durationMs: 1, to: started.store, now: Date(), takeId: "t1")
        let file = started.store.fileURL
        let saved = support.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: file, to: saved)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SpokenNoteIntake.addRecordedTake(audioFileName: "a.m4a", durationMs: 1, to: started.store, now: Date(), takeId: "t2")) {
            XCTAssertEqual($0 as? SpokenNoteIntake.IntakeError, .noteUnreadable)
        }
        XCTAssertThrowsError(try SpokenNoteIntake.applyTranscript(words: words(["Hi."]), forTake: "t1", in: started.store)) {
            XCTAssertEqual($0 as? SpokenNoteIntake.IntakeError, .noteUnreadable)
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue, "nothing was written over it")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: saved, to: file)
        XCTAssertEqual(started.store.load().takes.map(\.id), ["t1"], "the earlier dictation is intact once it can be read again")
    }

    func testTheTranscriptArrivesLaterAndIsNeverReplaced() throws {
        try writeAudio("a.m4a")
        try SpokenNoteIntake.addRecordedTake(audioFileName: "a.m4a", durationMs: 4_000, to: started.store, now: Date(), takeId: "t1")
        var note = try SpokenNoteIntake.applyTranscript(words: words(["Buy", "milk.", "Call", "Sam."]), forTake: "t1", in: started.store)
        XCTAssertEqual(note.text, "Buy milk. Call Sam.")
        XCTAssertEqual(started.store.load(), note)
        note = try SpokenNoteIntake.applyTranscript(words: words(["Something", "else."]), forTake: "t1", in: started.store)
        XCTAssertEqual(note.text, "Buy milk. Call Sam.", "dictated text is never replaced")
        note = try SpokenNoteIntake.applyTranscript(words: words(["Stray."]), forTake: "unknown", in: started.store)
        XCTAssertEqual(note.text, "Buy milk. Call Sam.")
        XCTAssertNotNil(note.playback(for: SpokenNote.SentenceRef(takeIndex: 0, sentenceIndex: 1)), "tap a sentence, hear its audio")
    }

    func testEmptyWordsLeaveATakeWithoutATranscriptSoALaterRunCanFillItIn() throws {
        try writeAudio("a.m4a")
        try SpokenNoteIntake.addRecordedTake(audioFileName: "a.m4a", durationMs: 4_000, to: started.store, now: Date(), takeId: "t1")
        XCTAssertFalse(try SpokenNoteIntake.applyTranscript(words: [], forTake: "t1", in: started.store).takes[0].hasTranscript)
        XCTAssertFalse(try SpokenNoteIntake.applyTranscript(words: words(["  ", ""]), forTake: "t1", in: started.store).takes[0].hasTranscript)
        XCTAssertEqual(try SpokenNoteIntake.applyTranscript(words: words(["Hello."]), forTake: "t1", in: started.store).text, "Hello.")
    }

    func testTheLibraryItemFollowsTheNoteAndNothingElseOfItChanges() throws {
        try writeAudio("a.m4a")
        try SpokenNoteIntake.addRecordedTake(audioFileName: "a.m4a", durationMs: 4_000, to: started.store, now: Date(), takeId: "t1")
        let note = try SpokenNoteIntake.applyTranscript(words: words(["Hello", "there."]), forTake: "t1", in: started.store)
        var renamed = started.item
        renamed.title = "Walk idea"
        let updated = SpokenNoteIntake.updatedItem(renamed, for: note)
        XCTAssertEqual(updated.text, "Hello there.")
        XCTAssertEqual(updated.title, "Walk idea")
        XCTAssertEqual(updated.id, started.item.id)
        XCTAssertEqual(updated.externalReference, "note://n1")
        let other = SpokenNoteItem.makeItem(note: SpokenNote(id: "other"), createdAt: Date())
        XCTAssertEqual(SpokenNoteIntake.updatedItem(other, for: note), other, "another note's item is left alone")
        var article = started.item
        article.mediaType = "article"
        XCTAssertEqual(SpokenNoteIntake.updatedItem(article, for: note), article, "an item that is not a spoken note is left alone")
    }
}
