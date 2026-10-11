import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// "Send one note per item when I mark it complete" (#587), the pass half: the composer builds an item note from a
/// real store, and the planner learns of a completion that writes no Margin row.
final class MarginNoteComposerItemNotesTests: XCTestCase {
    private var path = ""
    private var store: SQLiteSessionStore!
    private let completedAt = Date(timeIntervalSince1970: 1_777_000_000)

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "item-notes-\(UUID().uuidString).sqlite").path
        store = try SQLiteSessionStore(path: path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Fixtures

    private func addItem(_ n: Int, title: String? = nil, completedAt: Date?, deleted: Bool = false) throws {
        var item = Item(id: "item-\(n)", title: title ?? "Article \(n)", mediaType: "text", text: "Opening. Middle. End.", externalReference: nil, status: "ready")
        item.sourceCompletedAt = completedAt
        if deleted { item.deletedAt = Date(timeIntervalSince1970: 1_777_000_050) }
        try store.saveItem(item)
    }

    private func addSession(_ id: String, item n: Int, at seconds: TimeInterval) throws {
        try store.saveSession(Session(
            id: id, itemId: "item-\(n)", createdAt: Date(timeIntervalSince1970: seconds), status: "active",
            phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "item-\(n)",
            position: Position(charOffset: 5), completionPercent: 10, playbackRate: 1
        ))
    }

    private func addMargin(_ id: String, session: String, item n: Int, text: String?, startChar: Int = 0, status: String = "active") throws {
        try store.saveInterjection(Interjection(
            id: id, itemId: "item-\(n)", sessionId: session, targetType: .item, targetId: "item-\(n)",
            createdAt: Date(timeIntervalSince1970: 1_777_000_100), roughPercent: startChar,
            anchor: Anchor(anchorType: .text, startChar: startChar, endChar: startChar + 7, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: text, cleanedTranscript: nil,
            displayText: text, status: status, captureKind: .written
        ))
    }

    /// An item with two sessions, each with one Margin.
    private func addTwoSessionItem(_ n: Int = 1, completedAt: Date?) throws {
        try addItem(n, completedAt: completedAt)
        try addSession("s-\(n)-a", item: n, at: 1_777_000_000)
        try addSession("s-\(n)-b", item: n, at: 1_777_000_500)
        try addMargin("m-\(n)-a", session: "s-\(n)-a", item: n, text: "First thought.", startChar: 2)
        try addMargin("m-\(n)-b", session: "s-\(n)-b", item: n, text: "Second thought.", startChar: 12)
    }

    private func ageEverything() throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE records SET updated_at = '2020-01-01 00:00:00';", nil, nil, nil), SQLITE_OK)
    }

    // MARK: - The composer

    func testEachMarginIsStillTheDefaultAndNamesNoFile() throws {
        try addTwoSessionItem(completedAt: completedAt)
        let composed = try MarginNoteComposer.compose(store: store)
        XCTAssertEqual(Set(composed.notes.map(\.id)), ["s-1-a:m-1-a", "s-1-b:m-1-b"])
        XCTAssertTrue(composed.notes.allSatisfy { $0.fileName == nil }, "the writer names a Margin note itself")
    }

    func testACompletedItemGetsOneNoteHoldingTheMarginsOfEverySession() throws {
        try addTwoSessionItem(completedAt: completedAt)
        let composed = try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion)
        let note = try XCTUnwrap(composed.notes.first)
        XCTAssertEqual(composed.notes.count, 1, "no per-Margin notes in this mode")
        XCTAssertEqual(note.id, "item:item-1")
        XCTAssertEqual(note.fileName, ItemMarginNote.fileName(title: "Article 1", itemId: "item-1"))
        let properties = try FrontmatterParser.parse(note.markdown)
        XCTAssertEqual(properties["margin_count"], .plain("2"))
        XCTAssertEqual(properties["created"], .plain("2026-04-24T03:06:40Z"))
        XCTAssertEqual(properties["item_id"], .string("item-1"))
        let first = try XCTUnwrap(note.markdown.range(of: "First thought."))
        let second = try XCTUnwrap(note.markdown.range(of: "Second thought."))
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "the older session comes first")
    }

    func testOnlyOneSessionInScopeStillWritesTheWholeItem() throws {
        try addTwoSessionItem(completedAt: completedAt)
        let composed = try MarginNoteComposer.compose(store: store, sessionIds: ["s-1-b"], shape: .itemOnCompletion)
        let note = try XCTUnwrap(composed.notes.first)
        XCTAssertEqual(composed.sessionCount, 1)
        XCTAssertTrue(note.markdown.contains("First thought."), "a pass for one session must not shrink the item's note")
        XCTAssertTrue(note.markdown.contains("Second thought."))
    }

    func testAnItemNotCompleteWritesNothing() throws {
        try addTwoSessionItem(completedAt: nil)
        XCTAssertTrue(try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion).notes.isEmpty)
    }

    func testAnItemCompletedBeforeTheModeWasTurnedOnWritesNothing() throws {
        try addTwoSessionItem(1, completedAt: completedAt.addingTimeInterval(-3600))
        try addTwoSessionItem(2, completedAt: completedAt.addingTimeInterval(60))
        let composed = try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion, completedSince: completedAt)
        XCTAssertEqual(composed.notes.map(\.id), ["item:item-2"])
        let atTheMoment = try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion, completedSince: completedAt.addingTimeInterval(-3600))
        XCTAssertEqual(Set(atTheMoment.notes.map(\.id)), ["item:item-1", "item:item-2"], "the moment itself counts")
    }

    func testAnItemWithNoNoteworthyMarginOrADeletedItemWritesNothing() throws {
        try addItem(1, completedAt: completedAt)
        try addSession("s-1", item: 1, at: 1_777_000_000)
        try addMargin("m-1", session: "s-1", item: 1, text: "   ")
        try addMargin("m-2", session: "s-1", item: 1, text: "Deleted thought.", status: "deleted")
        try addItem(2, completedAt: completedAt, deleted: true)
        try addSession("s-2", item: 2, at: 1_777_000_000)
        try addMargin("m-3", session: "s-2", item: 2, text: "On a deleted item.")
        XCTAssertTrue(try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion).notes.isEmpty)
    }

    func testCompletingAgainRewritesTheSameFileWithTheNewDate() throws {
        try addTwoSessionItem(completedAt: completedAt)
        let first = try XCTUnwrap(MarginNoteComposer.compose(store: store, shape: .itemOnCompletion).notes.first)
        try addItem(1, completedAt: nil)   // Mark Unfinished
        XCTAssertTrue(try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion).notes.isEmpty)
        try addItem(1, completedAt: completedAt.addingTimeInterval(86_400))
        let again = try XCTUnwrap(MarginNoteComposer.compose(store: store, shape: .itemOnCompletion).notes.first)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.fileName, first.fileName, "same name, so the writer rewrites the file and adds no copy")
        XCTAssertNotEqual(again.markdown, first.markdown)
        XCTAssertTrue(again.markdown.contains("created: 2026-04-25T03:06:40Z"), again.markdown)
    }

    func testTwoItemsWithTheSameTitleGetDifferentFiles() throws {
        try addItem(1, title: "Episode 12", completedAt: completedAt)
        try addItem(2, title: "Episode 12", completedAt: completedAt)
        for n in 1...2 {
            try addSession("s-\(n)", item: n, at: 1_777_000_000)
            try addMargin("m-\(n)", session: "s-\(n)", item: n, text: "Thought \(n).")
        }
        let names = try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion).notes.compactMap(\.fileName)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(Set(names).count, 2)
    }

    // MARK: - The planner

    func testACompletionIsNotSeenWithoutTheHint() throws {
        try addTwoSessionItem(completedAt: nil)
        var planner = MarginNotePassPlanner()
        let first = try planner.plan(store: store, targetKey: "vault|/Notes")
        planner.commit(first, noteIDs: [], keptEditIDs: [])
        try ageEverything()

        try addItem(1, completedAt: completedAt)   // completing writes the item row only
        let quiet = try planner.plan(store: store, targetKey: "vault|/Notes")
        XCTAssertEqual(quiet.scope, .nothing, "no Margin or turn row changed, and the item row is too big to scan every minute")
    }

    func testTheHintRebuildsTheItemsSessionsOnceAndOnlyOnceCommitted() throws {
        try addTwoSessionItem(completedAt: nil)
        try addTwoSessionItem(2, completedAt: nil)
        var planner = MarginNotePassPlanner()
        let first = try planner.plan(store: store, targetKey: "vault|/Notes")
        planner.commit(first, noteIDs: [], keptEditIDs: [])
        try ageEverything()

        try addItem(1, completedAt: completedAt)
        planner.noteCompletion(ofItem: "item-1")
        let failed = try planner.plan(store: store, targetKey: "vault|/Notes")
        XCTAssertEqual(failed.scope, .sessions(["s-1-a", "s-1-b"]))
        // That pass failed and was not committed: the next one covers the same ground again.
        let retry = try planner.plan(store: store, targetKey: "vault|/Notes")
        XCTAssertEqual(retry.scope, .sessions(["s-1-a", "s-1-b"]))
        planner.commit(retry, noteIDs: ["item:item-1"], keptEditIDs: [])
        XCTAssertEqual(planner.folderSummary.saved, 1)

        let quiet = try planner.plan(store: store, targetKey: "vault|/Notes")
        XCTAssertEqual(quiet.scope, .nothing)
    }

    func testAHintMadeDuringAPassWaitsForTheNextOne() throws {
        try addTwoSessionItem(completedAt: nil)
        var planner = MarginNotePassPlanner()
        let first = try planner.plan(store: store, targetKey: "vault|/Notes")
        planner.commit(first, noteIDs: [], keptEditIDs: [])
        try ageEverything()

        let inFlight = try planner.plan(store: store, targetKey: "vault|/Notes")
        planner.noteCompletion(ofItem: "item-1")
        planner.commit(inFlight, noteIDs: [], keptEditIDs: [])
        let next = try planner.plan(store: store, targetKey: "vault|/Notes")
        XCTAssertEqual(next.scope, .sessions(["s-1-a", "s-1-b"]), "the completion came after the plan, so it is still owed")
    }

    func testAnItemNoteSurvivesAPassForOneOfItsSessionsInTheFolderCount() throws {
        try addTwoSessionItem(completedAt: completedAt)
        var planner = MarginNotePassPlanner()
        let first = try planner.plan(store: store, targetKey: "vault|/Notes")
        let composed = try MarginNoteComposer.compose(store: store, shape: .itemOnCompletion)
        planner.commit(first, noteIDs: composed.notes.map(\.id), keptEditIDs: [])
        try ageEverything()

        try addMargin("m-1-c", session: "s-1-b", item: 1, text: "Third thought.", startChar: 14)
        let pass = try planner.plan(store: store, targetKey: "vault|/Notes")
        XCTAssertEqual(pass.scope, .sessions(["s-1-b"]))
        let rebuilt = try MarginNoteComposer.compose(store: store, sessionIds: ["s-1-b"], shape: .itemOnCompletion)
        planner.commit(pass, noteIDs: rebuilt.notes.map(\.id), keptEditIDs: [])
        XCTAssertEqual(planner.folderSummary.saved, 1, "still one item note in the folder")
        XCTAssertTrue(try XCTUnwrap(rebuilt.notes.first).markdown.contains("Third thought."))
    }
}
