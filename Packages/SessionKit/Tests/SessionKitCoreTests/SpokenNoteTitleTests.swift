import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3663: a spoken note gets a useful title of its own, and the listener can rename it. The rules are pure, so they are
/// tested without a phone; the database half runs on a real SQLite file.
final class SpokenNoteTitleTests: XCTestCase {
    // 2023-11-08 14:18:00 UTC, read in UTC and en_US so the words are the same on every machine.
    private let day = Date(timeIntervalSince1970: 1_699_453_080)
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    private func automatic(_ text: String?, at date: Date? = nil) -> String {
        SpokenNoteTitle.automatic(createdAt: date ?? day, text: text, locale: english, timeZone: utc)
    }

    private func noteRow(title: String? = nil, text: String? = "", createdAt: Date? = nil, deletedAt: Date? = nil) -> Item {
        var item = Item(
            id: "spoken-note-n1", title: title ?? automatic(text), mediaType: "spoken_note", text: text,
            externalReference: "note://n1", status: "ready", createdAt: createdAt ?? day)
        item.deletedAt = deletedAt
        return item
    }

    // MARK: The title made for a note

    func testANewNoteIsNamedForItsDayAndTimeNeverBlankAndNeverJustUntitled() {
        let title = automatic("")
        XCTAssertTrue(title.hasPrefix("Spoken note, Nov 8"), title)
        XCTAssertNotEqual(title, "Untitled")
        XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty)
        // Two notes made a day apart do not share a name.
        XCTAssertNotEqual(title, automatic("", at: day.addingTimeInterval(86_400)))
        XCTAssertEqual(automatic(nil), title, "no transcript and an empty one are the same")
    }

    func testOnceItHasWordsTheTitleIsTheDayAndTheFirstWords() {
        XCTAssertEqual(automatic("Buy milk and call the dentist. Then pick up the kids."), "Nov 8 · Buy milk and call the dentist")
        XCTAssertEqual(automatic("Buy milk."), "Nov 8 · Buy milk", "the full stop that ended the phrase is dropped")
    }

    func testAnItemWithNoDateIsJustSpokenNote() {
        XCTAssertEqual(SpokenNoteTitle.automatic(createdAt: nil, text: "Hello there"), "Spoken note")
    }

    func testFirstWordsForNeighbouringInputs() {
        let cases: [(String?, String?)] = [
            (nil, nil),
            ("", nil),
            ("   \n\t ", nil),
            ("...", nil),
            ("— ?!", nil),
            ("Hello", "Hello"),
            ("  spaced   out \n words ", "spaced out words"),
            ("one two three four five six seven eight", "one two three four five six"),
            ("Is this working?", "Is this working"),
            ("Wait, what? No...", "Wait, what? No"),
            ("Café ñandú 東京 déjà vu", "Café ñandú 東京 déjà vu"),
            ("Remind me 😀", "Remind me 😀"),
            ("\"Quoted\" start", "\"Quoted\" start"),
            ("He said \"stop.\"", "He said \"stop.\""),
            ("Line one\nLine two\n\nLine three", "Line one Line two Line three")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenNoteTitle.firstWords(of: input), expected, "[\(input ?? "nil")]")
        }
    }

    func testVeryLongWordsAndPhrasesAreCutNotDropped() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(SpokenNoteTitle.firstWords(of: long)?.count, 48)
        // Words past the character limit are left off at a word break.
        let words = "extraordinarily unbelievably incomprehensibly disproportionately counterintuitively"
        let phrase = try! XCTUnwrap(SpokenNoteTitle.firstWords(of: words))
        XCTAssertLessThanOrEqual(phrase.count, 48)
        XCTAssertTrue(words.hasPrefix(phrase), "cut at a word, not in the middle of one")
        XCTAssertFalse(phrase.hasSuffix(" "))
    }

    // MARK: A title the listener types

    func testATypedTitleIsMadeFitToKeep() {
        let cases: [(String, String?)] = [
            ("Plumber call", "Plumber call"),
            ("  padded  ", "padded"),
            ("two\nlines\tand   spaces", "two lines and spaces"),
            ("", nil),
            ("   ", nil),
            ("\n\t\r", nil),
            ("\u{202E}reversed\u{202C}", "reversed"),
            ("Ideas: 100% — “maybe” (not)?", "Ideas: 100% — “maybe” (not)?"),
            ("Résumé de la réunion 📝", "Résumé de la réunion 📝"),
            ("日本語のメモ", "日本語のメモ"),
            ("non\u{00A0}breaking\u{2028}separators", "non breaking separators"),
            ("a/b\\c:d*e", "a/b\\c:d*e") // a title is not a file name; the export cleans it for the file only
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SpokenNoteTitle.normalized(input), expected, "[\(input)]")
        }
    }

    func testAVeryLongTitleIsCutToTheLimitOnWholeCharacters() throws {
        let long = String(repeating: "é", count: 500)
        XCTAssertEqual(SpokenNoteTitle.normalized(long)?.count, SpokenNoteTitle.maxLength)
        let emoji = String(repeating: "👩‍👩‍👧", count: 200) // one character, several scalars
        let cut = try XCTUnwrap(SpokenNoteTitle.normalized(emoji))
        XCTAssertEqual(cut.count, SpokenNoteTitle.maxLength)
        XCTAssertEqual(cut, String(repeating: "👩‍👩‍👧", count: SpokenNoteTitle.maxLength), "no character is split")
        // A cut that lands on a space drops it.
        let spaced = String(repeating: "a", count: SpokenNoteTitle.maxLength - 1) + " tail"
        XCTAssertEqual(SpokenNoteTitle.normalized(spaced), String(repeating: "a", count: SpokenNoteTitle.maxLength - 1))
    }

    func testTheSameTitleTwiceIsAllowed() throws {
        let a = try XCTUnwrap(SpokenNoteTitle.renamed(noteRow(), to: "Groceries"))
        var other = noteRow()
        other.id = "spoken-note-n2"
        let b = try XCTUnwrap(SpokenNoteTitle.renamed(other, to: "Groceries"))
        XCTAssertEqual(a.title, b.title)
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: Renaming a row

    func testRenamingChangesOnlyTheTitle() throws {
        var row = noteRow(text: "Call the plumber.")
        row.transcriptId = "transcript-1"
        row.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///a.m4a", durationMs: 1000, nativeMediaId: "m")
        row.sourceCompletedAt = Date(timeIntervalSince1970: 5)
        let renamed = try XCTUnwrap(SpokenNoteTitle.renamed(row, to: "  Plumber  call "))
        XCTAssertEqual(renamed.title, "Plumber call")
        var expected = row
        expected.title = "Plumber call"
        XCTAssertEqual(renamed, expected, "nothing but the title differs")
    }

    func testRenamingToTheSameTitleOrOnAnUnrenameableRowChangesNothing() {
        let row = noteRow(title: "Plumber call", text: "Call the plumber.")
        XCTAssertNil(SpokenNoteTitle.renamed(row, to: "Plumber call"))
        XCTAssertNil(SpokenNoteTitle.renamed(row, to: " Plumber   call "))
        XCTAssertNil(SpokenNoteTitle.renamed(noteRow(deletedAt: Date(timeIntervalSince1970: 9)), to: "New"), "a trashed note is not renamed")
        var text = row
        text.mediaType = "text"
        XCTAssertNil(SpokenNoteTitle.renamed(text, to: "New"), "only a spoken note")
    }

    func testSavingTheTitleItAlreadyHasIsNotARenameEvenWhenItHoldsOddSpaces() {
        // The made-up title can hold a narrow no-break space (U+202F) before "PM"; typing nothing new must not rewrite it.
        let odd = noteRow(title: "Spoken note, Nov 8 at 2:18\u{202F}PM", text: "")
        XCTAssertNil(SpokenNoteTitle.renamed(odd, to: odd.title))
        XCTAssertNil(SpokenNoteTitle.renamed(odd, to: "Spoken note, Nov 8 at 2:18 PM"), "the same words with a plain space")
    }

    func testABlankTitleGoesBackToTheMadeUpOneWhichFollowsTheWordsAgain() throws {
        let row = noteRow(title: "Plumber call", text: "Call the plumber about the sink.")
        let reset = try XCTUnwrap(SpokenNoteTitle.renamed(row, to: "   "))
        XCTAssertEqual(reset.title, SpokenNoteTitle.automatic(createdAt: day, text: "Call the plumber about the sink."))
        XCTAssertTrue(SpokenNoteTitle.isAutomatic(reset), "it follows the words again")
    }

    // MARK: The title follows the words only while it is the made-up one

    func testTheMadeUpTitleFollowsTheTranscriptInTheDatabaseMerge() throws {
        let stored = noteRow(text: "")
        let incoming = noteRow(text: "Call the plumber about the sink.")
        // `isAutomatic` reads the current locale; build the stored row the way the app would.
        var storedHere = stored
        storedHere.title = SpokenNoteTitle.automatic(createdAt: stored.createdAt, text: stored.text)
        var incomingHere = incoming
        incomingHere.title = storedHere.title
        let saved = try XCTUnwrap(SpokenNoteItemMerge.rowToSave(stored: storedHere, incoming: incomingHere, isFirstSave: false))
        XCTAssertEqual(saved.title, SpokenNoteTitle.automatic(createdAt: stored.createdAt, text: "Call the plumber about the sink."))
        XCTAssertTrue(saved.title.contains("Call the plumber about the sink"), saved.title)
    }

    func testATitleTheListenerTypedIsNeverChangedByAnArrivingTranscript() {
        let stored = noteRow(title: "Plumber call", text: "")
        let saved = SpokenNoteItemMerge.rowToSave(stored: stored, incoming: noteRow(title: "whatever", text: "Call the plumber."), isFirstSave: false)
        XCTAssertEqual(saved?.title, "Plumber call")
        XCTAssertEqual(saved?.text, "Call the plumber.")
    }

    func testAnOlderNotesTitleIsKeptUntilRenamed() {
        // Notes made before this change are called "Spoken note" and have a date: not what is made up now.
        let stored = noteRow(title: "Spoken note", text: "")
        let saved = SpokenNoteItemMerge.rowToSave(stored: stored, incoming: noteRow(title: "Spoken note", text: "Words."), isFirstSave: false)
        XCTAssertEqual(saved?.title, "Spoken note")
    }

    func testTheRecordingsOwnCopyOfTheItemFollowsTheWordsToo() {
        var note = SpokenNote(id: "n1")
        let started = SpokenNoteItem.makeItem(note: note, createdAt: day)
        XCTAssertTrue(started.title.hasPrefix("Spoken note,"), started.title)
        note.appendTake(SpokenNoteTake(
            id: "t1", audioFileName: "t1.m4a", durationMs: 1000, createdAt: day,
            sentences: [SpokenNoteSentence(text: "Call the plumber.", startMs: 0, endMs: 900)]))
        let updated = SpokenNoteIntake.updatedItem(started, for: note)
        XCTAssertTrue(updated.title.hasSuffix("· Call the plumber"), updated.title)
        // A rename is not undone by the next transcript.
        var renamed = started
        renamed.title = "Plumber call"
        XCTAssertEqual(SpokenNoteIntake.updatedItem(renamed, for: note).title, "Plumber call")
    }

    func testAMadeUpTitleSurvivesTheDatabaseShapeTheLastBuildReads() throws {
        let item = SpokenNoteItem.makeItem(note: SpokenNote(id: "n1"), createdAt: day)
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(Item.self, from: data).title, item.title, "the title is plain text on the row")
    }

    // MARK: On a real database

    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "spoken-note-title-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func savedRow(_ store: SQLiteSessionStore, text: String = "Call the plumber about the sink.") throws -> Item {
        var row = SpokenNoteItem.makeItem(note: SpokenNote(id: "n1"), createdAt: day)
        row.text = text
        row.title = SpokenNoteTitle.automatic(createdAt: day, text: text)
        row.transcriptId = "transcript-spoken-note-n1"
        row.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///a.m4a", durationMs: 1000, nativeMediaId: "m")
        try store.saveItem(row)
        return row
    }

    func testRenamingARowKeepsItsAudioTranscriptAndSession() throws {
        let store = try SQLiteSessionStore(path: path)
        let row = try savedRow(store)
        let title = try store.renameSpokenNote(itemId: row.id, to: "  Plumber \n call  ")
        XCTAssertEqual(title, "Plumber call")
        let stored = try store.loadItem(id: row.id)
        var expected = row
        expected.title = "Plumber call"
        XCTAssertEqual(stored, expected, "the audio reference, transcript id and text are as they were")
    }

    func testARenameSticksWhenAnotherTranscriptArrivesAfterwards() throws {
        let store = try SQLiteSessionStore(path: path)
        let row = try savedRow(store, text: "")
        XCTAssertEqual(try store.renameSpokenNote(itemId: row.id, to: "Plumber call"), "Plumber call")
        var incoming = row
        incoming.text = "Call the plumber."
        try store.write(incoming, isFirstSave: false)
        let stored = try store.loadItem(id: row.id)
        XCTAssertEqual(stored.title, "Plumber call")
        XCTAssertEqual(stored.text, "Call the plumber.")
    }

    func testANoteNeverRenamedStillFollowsItsTranscriptOnTheDatabase() throws {
        let store = try SQLiteSessionStore(path: path)
        let row = try savedRow(store, text: "")
        var incoming = row
        incoming.text = "Call the plumber about the sink."
        try store.write(incoming, isFirstSave: false)
        XCTAssertEqual(try store.loadItem(id: row.id).title,
                       SpokenNoteTitle.automatic(createdAt: day, text: "Call the plumber about the sink."))
    }

    func testRenamingBlankPutsTheMadeUpTitleBack() throws {
        let store = try SQLiteSessionStore(path: path)
        let row = try savedRow(store)
        _ = try store.renameSpokenNote(itemId: row.id, to: "Plumber call")
        let title = try store.renameSpokenNote(itemId: row.id, to: "")
        XCTAssertEqual(title, SpokenNoteTitle.automatic(createdAt: day, text: row.text))
    }

    func testAMissingTrashedOrNonNoteRowIsNotRenamed() throws {
        let store = try SQLiteSessionStore(path: path)
        XCTAssertNil(try store.renameSpokenNote(itemId: "spoken-note-gone", to: "New"))

        let row = try savedRow(store)
        try store.moveItemToTrash(id: row.id)
        XCTAssertNil(try store.renameSpokenNote(itemId: row.id, to: "New"))
        XCTAssertEqual(try store.loadItem(id: row.id).title, row.title, "a trashed note keeps its name")

        let article = Item(id: "article-1", title: "An article", mediaType: "text", text: "Body", externalReference: nil, status: "ready")
        try store.saveItem(article)
        XCTAssertNil(try store.renameSpokenNote(itemId: article.id, to: "Hijack"))
        XCTAssertEqual(try store.loadItem(id: article.id).title, "An article")
    }

    func testRenamingToTheSameTitleWritesNothingNew() throws {
        let store = try SQLiteSessionStore(path: path)
        let row = try savedRow(store)
        let revision = store.itemRevision(id: row.id)
        XCTAssertEqual(try store.renameSpokenNote(itemId: row.id, to: row.title), row.title)
        XCTAssertEqual(store.itemRevision(id: row.id), revision)
    }

    func testTheExportedFileNameFollowsTheNewTitle() {
        XCTAssertEqual(SpokenNoteExport.fileBaseName(forTitle: "Plumber call: sink/pipe?"), "Plumber call sink pipe")
        XCTAssertEqual(SpokenNoteExport.fileBaseName(forTitle: automatic("Buy milk and call the dentist")), "Nov 8 · Buy milk and call the dentist")
    }
}
