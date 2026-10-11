import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// A destination's choices (#492), built from a real store: which Margins a note folder gets, whether each note carries
/// the passage around it, and which transcript it quotes. A destination left at its defaults must write exactly what the
/// single notes folder always wrote, or every existing note would be rewritten.
final class MarginNoteComposerContentTests: XCTestCase {
    private var path = ""
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "note-content-\(UUID().uuidString).sqlite").path
        store = try SQLiteSessionStore(path: path)
        var item = Item(id: "item-1", title: "Article", mediaType: "text", text: "Opening. Middle. End.", externalReference: "https://example.com/article", status: "ready")
        item.sourceCompletedAt = nil
        try store.saveItem(item)
        try store.saveSession(Session(
            id: "s-1", itemId: "item-1", createdAt: Date(timeIntervalSince1970: 1_777_000_000), status: "active",
            phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "item-1",
            position: Position(charOffset: 5), completionPercent: 10, playbackRate: 1
        ))
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func addMargin(
        _ id: String, kind: InterjectionCaptureKind, original: String?, cleaned: String? = nil, starred: Bool? = nil
    ) throws {
        try store.saveInterjection(Interjection(
            id: id, itemId: "item-1", sessionId: "s-1", targetType: .item, targetId: "item-1",
            createdAt: Date(timeIntervalSince1970: 1_777_000_100), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 9, endChar: 15, anchorBefore: "Opening.", anchorAfter: "End."),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: original, cleanedTranscript: cleaned,
            displayText: cleaned ?? original, status: "active", isStarredForSharing: starred, captureKind: kind
        ))
    }

    private func markdown(of marginId: String, _ content: MarginNoteContent) throws -> String {
        let composed = try MarginNoteComposer.compose(store: store, content: content)
        return try XCTUnwrap(composed.notes.first { $0.id == "s-1:" + marginId }, "no note for \(marginId)").markdown
    }

    func testAStandardDestinationWritesExactlyWhatTheSingleFolderAlwaysDid() throws {
        try addMargin("m-1", kind: .audio, original: "um raw words", cleaned: "Clean words.")
        let before = try MarginNoteComposer.compose(store: store)
        let after = try MarginNoteComposer.compose(store: store, content: MarginOutputDestination(name: "Notes folder", bookmark: Data([1])).content)
        XCTAssertEqual(after.notes, before.notes)
        XCTAssertEqual(MarginOutputDestination(name: "n", bookmark: Data([1])).content, .standard)
        let note = try XCTUnwrap(before.notes.first).markdown
        XCTAssertTrue(note.contains("Clean words."), note)
        XCTAssertTrue(note.contains("## Context before"), note)
    }

    func testAStarredDestinationGetsOnlyStarredMargins() throws {
        try addMargin("m-all", kind: .written, original: "Plain.")
        try addMargin("m-star", kind: .written, original: "Starred.", starred: true)
        try addMargin("m-unstarred", kind: .written, original: "Explicitly false.", starred: false)

        let everything = try MarginNoteComposer.compose(store: store, content: MarginNoteContent(scope: .all))
        let starred = try MarginNoteComposer.compose(store: store, content: MarginNoteContent(scope: .starred))

        XCTAssertEqual(Set(everything.notes.map(\.id)), ["s-1:m-all", "s-1:m-star", "s-1:m-unstarred"])
        XCTAssertEqual(starred.notes.map(\.id), ["s-1:m-star"])
        XCTAssertEqual(starred.notes.first?.markdown, try markdown(of: "m-star", .standard), "a starred note reads the same as it does in an all-Margins folder")
    }

    func testStarringAMarginLaterPutsItInThePlannersNextPass() throws {
        try addMargin("m-1", kind: .written, original: "Later starred.")
        var planner = MarginNotePassPlanner()
        let first = try planner.plan(store: store, targetKey: "starred|folder")
        planner.commit(first, noteIDs: [], keptEditIDs: [])
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE records SET updated_at = '2020-01-01 00:00:00';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertEqual(try planner.plan(store: store, targetKey: "starred|folder").scope, .nothing)

        try addMargin("m-1", kind: .written, original: "Later starred.", starred: true)

        XCTAssertEqual(try planner.plan(store: store, targetKey: "starred|folder").scope, .sessions(["s-1"]))
        let composed = try MarginNoteComposer.compose(store: store, sessionIds: ["s-1"], content: MarginNoteContent(scope: .starred))
        XCTAssertEqual(composed.notes.map(\.id), ["s-1:m-1"])
    }

    func testLeavingOutContextDropsThePassageButKeepsWhereTheNoteCameFrom() throws {
        try addMargin("m-1", kind: .written, original: "A thought.")
        let with = try markdown(of: "m-1", .standard)
        let without = try markdown(of: "m-1", MarginNoteContent(includesContext: false))

        XCTAssertTrue(with.contains("## Context before") && with.contains("Opening.") && with.contains("## Context after"), with)
        XCTAssertFalse(without.contains("## Context before"), without)
        XCTAssertFalse(without.contains("## Context after"), without)
        XCTAssertFalse(without.contains("Opening."), without)
        for kept in ["# Article", "Source: https://example.com/article", "Position: 10%", "A thought.", "spokenmargins://margin?session=s-1&margin=m-1"] {
            XCTAssertTrue(without.contains(kept), "\(kept) missing from:\n\(without)")
        }
    }

    func testTheOriginalTranscriptReplacesTheCleanedOneForASpokenMarginOnly() throws {
        try addMargin("m-spoken", kind: .audio, original: "um so the raw words", cleaned: "So the clean words.")
        try addMargin("m-no-original", kind: .audio, original: nil, cleaned: "Only cleaned.")
        try addMargin("m-blank-original", kind: .audio, original: "  ", cleaned: "Cleaned wins over blank.")
        try addMargin("m-written", kind: .written, original: "Typed words.")
        let original = MarginNoteContent(text: .original)

        let spoken = try markdown(of: "m-spoken", original)
        XCTAssertTrue(spoken.contains("um so the raw words"), spoken)
        XCTAssertFalse(spoken.contains("So the clean words."), spoken)
        XCTAssertTrue(try markdown(of: "m-spoken", .standard).contains("So the clean words."))
        XCTAssertTrue(try markdown(of: "m-no-original", original).contains("Only cleaned."))
        XCTAssertTrue(try markdown(of: "m-blank-original", original).contains("Cleaned wins over blank."))
        XCTAssertEqual(try markdown(of: "m-written", original), try markdown(of: "m-written", .standard))
    }

    func testTheChoicesCombine() throws {
        try addMargin("m-1", kind: .audio, original: "raw", cleaned: "Clean.", starred: true)
        try addMargin("m-2", kind: .audio, original: "raw two", cleaned: "Clean two.")
        let content = MarginNoteContent(scope: .starred, includesContext: false, text: .original)
        let composed = try MarginNoteComposer.compose(store: store, content: content)
        XCTAssertEqual(composed.notes.map(\.id), ["s-1:m-1"])
        let note = try XCTUnwrap(composed.notes.first).markdown
        XCTAssertTrue(note.contains("raw") && !note.contains("Clean.") && !note.contains("## Context before"), note)
    }
}
