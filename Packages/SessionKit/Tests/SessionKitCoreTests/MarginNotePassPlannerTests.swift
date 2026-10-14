import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1192: the notes folder used to rebuild every note every minute (37 passes, 142 s in 18 minutes on a Library of
/// 273 sessions). A pass now rebuilds only what changed, and nothing when nothing did.
final class MarginNotePassPlannerTests: XCTestCase {
    private var path = ""
    private var store: SQLiteSessionStore!
    private var planner = MarginNotePassPlanner()
    private let target = "vault|/Notes"

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "margin-pass-\(UUID().uuidString).sqlite").path
        store = try SQLiteSessionStore(path: path)
        planner = MarginNotePassPlanner()
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Fixtures

    private func addSession(_ n: Int, margins: Int = 1) throws {
        try store.saveItem(Item(id: "item-\(n)", title: "Article \(n)", mediaType: "text", text: "Opening. Middle. End.", externalReference: nil, status: "ready"))
        try store.saveSession(Session(
            id: "session-\(n)", itemId: "item-\(n)", createdAt: Date(timeIntervalSince1970: 1_777_000_000), status: "active",
            phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "item-\(n)",
            position: Position(charOffset: 5), completionPercent: 10, playbackRate: 1
        ))
        for m in 1...max(1, margins) where margins > 0 { try saveMargin(session: n, margin: m, text: "Thought \(m) on article \(n).") }
    }

    private func saveMargin(session n: Int, margin m: Int, text: String?, status: String = "active") throws {
        try store.saveInterjection(Interjection(
            id: "ij-\(n)-\(m)", itemId: "item-\(n)", sessionId: "session-\(n)", targetType: .item, targetId: "item-\(n)",
            createdAt: Date(timeIntervalSince1970: 1_777_000_100), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "", anchorAfter: " Middle."),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: text, cleanedTranscript: nil,
            displayText: text, status: status, captureKind: .written
        ))
    }

    /// Moves every row's clock back, so what is already in the store reads as old, settled data.
    private func ageEverything() throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "UPDATE records SET updated_at = '2020-01-01 00:00:00';", nil, nil, nil), SQLITE_OK)
    }

    /// One pass as the delivery runs it: plan, build the notes for the plan, commit.
    @discardableResult
    private func runPass(at now: Date = Date(), target: String? = nil, kept: Set<String> = []) throws -> (scope: MarginNotePassPlanner.Scope, notes: [MarginNoteComposer.Note], sessionsRead: Int) {
        let pass = try planner.plan(store: store, targetKey: target ?? self.target, now: now)
        var notes: [MarginNoteComposer.Note] = []
        var read = 0
        switch pass.scope {
        case .nothing: break
        case .everything:
            let composed = try MarginNoteComposer.compose(store: store)
            notes = composed.notes; read = composed.sessionCount
        case .sessions(let ids):
            let composed = try MarginNoteComposer.compose(store: store, sessionIds: ids)
            notes = composed.notes; read = composed.sessionCount
        }
        planner.commit(pass, noteIDs: notes.map(\.id), keptEditIDs: kept)
        return (pass.scope, notes, read)
    }

    // MARK: - Tests

    func testAPassWithNothingNewReadsNoSessionsAndOneNewMarginMakesExactlyOneNote() throws {
        for n in 1...300 { try addSession(n) }
        let first = try runPass()
        XCTAssertEqual(first.scope, .everything)
        XCTAssertEqual(first.notes.count, 300)
        XCTAssertEqual(first.sessionsRead, 300)
        try ageEverything()

        let quiet = try runPass()
        XCTAssertEqual(quiet.scope, .nothing, "nothing changed: no per-session work")
        XCTAssertEqual(quiet.sessionsRead, 0)
        XCTAssertTrue(quiet.notes.isEmpty)

        try saveMargin(session: 42, margin: 2, text: "A second thought.")
        let one = try runPass()
        XCTAssertEqual(one.scope, .sessions(["session-42"]))
        XCTAssertEqual(one.sessionsRead, 1)
        // The session's other Margin is rebuilt with it, but nothing from the other 299 sessions.
        XCTAssertEqual(Set(one.notes.map(\.id)), ["session-42:ij-42-1", "session-42:ij-42-2"])
        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 301, keptEdits: 0))
    }

    func testARowSavedRightAfterAPassIsNotMissedEvenInTheSameSecond() throws {
        try addSession(1)
        try runPass()
        // No aging: the Margin lands in the same second the pass planned in.
        try saveMargin(session: 1, margin: 2, text: "Right away.")
        XCTAssertEqual(try runPass().scope, .sessions(["session-1"]))
        // Seen again once while that second is unsettled, then quiet.
        try ageEverything()
        XCTAssertEqual(try runPass().scope, .nothing)
    }

    func testATranscriptThatArrivesRebuildsItsItemsSessionsOnceAndARenameWaitsForTheRepairPass() throws {
        try addSession(1); try addSession(2)
        let start = Date()
        try runPass(at: start)
        try ageEverything()

        // A note's context comes from the item's transcript, so its arrival rebuilds that item's notes, once.
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-2", itemId: "item-2", createdAt: start,
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "segment-2", startMs: 0, endMs: 5_000, text: "Opening. Middle. End.")],
                chapters: [], durationMs: 5_000
            )
        ))
        try ageEverything()
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(60)).scope, .sessions(["session-2"]))
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(120)).scope, .nothing)

        // An item's own payload is its whole article, so a rename isn't watched for; the repair pass writes it.
        try store.saveItem(Item(id: "item-2", title: "Renamed article", mediaType: "text", text: "Opening. Middle. End.", externalReference: nil, status: "ready"))
        try ageEverything()
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(180)).scope, .nothing)
        let repair = try runPass(at: start.addingTimeInterval(31 * 60))
        XCTAssertEqual(repair.scope, .everything)
        XCTAssertTrue(repair.notes.contains { $0.markdown.contains("Renamed article") })
    }

    func testTheFirstRealTranscriptRebuildsNotesEvenWhenAChaptersOnlyTimelineWasThereFirst() throws {
        try addSession(1); try addSession(2)
        let start = Date()
        // Publisher chapters are saved as a timeline with no segments, under the same row id the transcript later uses.
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-2", itemId: "item-2", createdAt: start,
            timeline: TranscriptTimeline(
                segments: [],
                chapters: [MediaTimelineChapter(id: "chapter-1", title: "Intro", startMs: 0, transcriptSegmentId: "segment-2")],
                durationMs: 5_000
            )
        ))
        try runPass(at: start)
        try ageEverything()
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(60)).scope, .nothing)

        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-2", itemId: "item-2", createdAt: start,
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "segment-2", startMs: 0, endMs: 5_000, text: "Opening. Middle. End.")],
                chapters: [MediaTimelineChapter(id: "chapter-1", title: "Intro", startMs: 0, transcriptSegmentId: "segment-2")],
                durationMs: 5_000
            )
        ))
        try ageEverything()
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(120)).scope, .sessions(["session-2"]))
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(180)).scope, .nothing)
    }

    func testEditingOrDeletingAMarginChangesOnlyItsSession() throws {
        try addSession(1); try addSession(2)
        try runPass()
        try ageEverything()

        try saveMargin(session: 1, margin: 1, text: "Reworded.")
        let edited = try runPass()
        XCTAssertEqual(edited.scope, .sessions(["session-1"]))
        XCTAssertTrue(try XCTUnwrap(edited.notes.first).markdown.contains("Reworded."))
        try ageEverything()

        try saveMargin(session: 2, margin: 1, text: "Thought 1 on article 2.", status: "deleted")
        let deleted = try runPass()
        XCTAssertEqual(deleted.scope, .sessions(["session-2"]))
        XCTAssertTrue(deleted.notes.isEmpty, "a deleted Margin has no note")
        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 0), "the deleted Margin no longer counts")
    }

    func testAnotherFolderRebuildsEverything() throws {
        try addSession(1); try addSession(2)
        try runPass()
        try ageEverything()
        XCTAssertEqual(try runPass().scope, .nothing)
        XCTAssertEqual(try runPass(target: "other|/Elsewhere").scope, .everything)
        XCTAssertEqual(try runPass(target: "other|/Elsewhere").scope, .nothing)
    }

    func testARepairPassRebuildsEverythingAfterThirtyMinutesAndWhenTheClockGoesBackwards() throws {
        try addSession(1)
        let start = Date()
        try runPass(at: start)
        try ageEverything()
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(29 * 60)).scope, .nothing)
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(31 * 60)).scope, .everything)
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(32 * 60)).scope, .nothing, "the repair pass restarts the 30 minutes")
        XCTAssertEqual(try runPass(at: start.addingTimeInterval(-3600)).scope, .everything, "a clock set backwards can hide changes")
    }

    /// An item note (`item:<id>`) isn't tied to one session, so a session pass can't tell by prefix that it was rebuilt.
    func testAnItemNoteTheListenerDeletedStopsCountingAsEditedWhenItIsWrittenAgain() throws {
        try addSession(1)
        let first = try planner.plan(store: store, targetKey: target)
        planner.commit(first, noteIDs: ["item:item-1", "session-1:ij-1-1"], keptEditIDs: ["item:item-1"])
        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 1))
        try ageEverything()

        try saveMargin(session: 1, margin: 2, text: "Another thought.")
        let second = try planner.plan(store: store, targetKey: target)
        XCTAssertEqual(second.scope, .sessions(["session-1"]))
        planner.commit(second, noteIDs: ["item:item-1"], keptEditIDs: [])

        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 1, keptEdits: 0), "the file was written again, so it is no longer an edit")
    }

    func testTheFolderSummaryCountsEveryNoteAndEveryEditedNote() throws {
        try addSession(1, margins: 2); try addSession(2)
        try runPass(kept: ["session-1:ij-1-1"])
        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 2, keptEdits: 1))
        try ageEverything()

        // A later pass for session 2 alone doesn't forget session 1's edited note.
        try saveMargin(session: 2, margin: 2, text: "More.")
        try runPass()
        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 3, keptEdits: 1))
        try ageEverything()

        // Once the listener's edit is gone, the rebuilt note counts as saved again.
        try saveMargin(session: 1, margin: 1, text: "Reworded.")
        try runPass(kept: [])
        XCTAssertEqual(planner.folderSummary, MarginNoteDelivery.Summary(saved: 4, keptEdits: 0))
    }
}
