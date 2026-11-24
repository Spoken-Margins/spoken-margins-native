import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4233 Design 6b: the item side of a move, on a real SQLite file. A moved Margin keeps its words, its recording and its
/// capture time; the item's session (resume point, percent, finished state, `updatedAt`) is never written; all of it is
/// written in one transaction or none of it; and Undo takes it back off only while the listener hasn't changed it.
final class LiveMarginMoveItemSideTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private var directory: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "live-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func episode(id: String = "ep") -> Item {
        Item(
            id: id, title: "Episode \(id)", mediaType: "podcast", text: nil, externalReference: "https://example.com/\(id).mp3",
            status: "ready", externalReferenceType: "podcast",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///tmp/\(id).mp3", durationMs: 600_000, nativeMediaId: "\(id)-audio"))
    }

    private func session(
        for itemId: String, status: String = "in_progress", phase: SessionPhase = .itemPlayback, percent: Int = 70, resumeMs: Int = 421_000
    ) -> Session {
        Session(
            id: "s-\(itemId)", itemId: itemId, createdAt: at(-1_000), updatedAt: at(-900), status: status, phase: phase,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "\(itemId)-audio",
            position: Position(charOffset: 0, mediaTimeMs: resumeMs), completionPercent: percent, playbackRate: 1)
    }

    private func seed(_ item: Item, _ session: Session) throws {
        try store.saveItem(item)
        try store.saveSession(session)
    }

    private func spoken(_ id: String, at offset: TimeInterval, words: String = "", hint: LiveSessionPlayingThen? = nil) -> LiveSessionMargin {
        var margin = LiveSessionMargin(
            id: id, text: words, markedAt: at(offset).addingTimeInterval(0.25), audioPath: "SpokenMargins/interjections/\(id).m4a",
            durationMs: 3_000, spokenOn: "watch")
        margin.playingThen = hint
        margin.deviceMarkedAt = at(offset - 2)
        margin.clockNote = "Watch clock 2.0 s ahead, corrected"
        return margin
    }

    private func quick(_ margins: [LiveSessionMargin]) -> LiveSession {
        var session = LiveSession(id: "quick-1", title: "Quick session", startedAt: margins.first!.markedAt, isQuick: true)
        for margin in margins { session.add(margin) }
        return session
    }

    private func plan(_ margins: [LiveSessionMargin], itemId: String = "ep") throws -> LiveMarginMove.Plan {
        try LiveMarginMove.plan(margins: margins, session: quick(margins), itemId: itemId, repository: store)
    }

    // MARK: What is kept

    func testAMovedMarginKeepsItsWordsRecordingAndCaptureTime() throws {
        try seed(episode(), session(for: "ep"))
        let placed = spoken("p", at: 1, words: "About the tide", hint: .init(itemId: "ep", positionMs: 64_000, source: .playerRun))
        let unplaced = spoken("u", at: 2)
        var written = LiveSessionMargin(id: "w", text: "Typed note", markedAt: at(3))
        written.filingNote = LiveSessionFiling.afterEndNote
        let audio = directory.appending(path: "p.m4a")
        try Data("voice".utf8).write(to: audio)

        let moved = try LiveMarginMove.execute(plan: try plan([placed, unplaced, written]), repository: store, movedAt: at(500))
        XCTAssertEqual(moved.count, 3)
        let reread = try store.loadInterjections(sessionId: "s-ep")
        let byId = Dictionary(uniqueKeysWithValues: reread.map { ($0.id, $0) })

        let p = try XCTUnwrap(byId["ij-moved-p"])
        XCTAssertEqual(p.transcript, "About the tide")
        XCTAssertEqual(p.audioPath, placed.audioPath, "the same file, not a copy")
        XCTAssertEqual(p.createdAt.timeIntervalSince1970, placed.markedAt.timeIntervalSince1970, accuracy: 1, "the store keeps whole seconds")
        XCTAssertEqual(p.anchor.mediaTimeMs, 64_000)
        XCTAssertEqual(p.roughPercent, 10)
        XCTAssertTrue(p.hasPlace)
        XCTAssertEqual(p.targetType, .item)
        XCTAssertEqual(p.targetId, "ep")
        XCTAssertEqual(p.captureKind, .audio)
        XCTAssertEqual(p.audioStatus, "saved")
        XCTAssertEqual(p.transcriptionStatus, "transcribed")
        XCTAssertEqual(p.anchorContextStatus, .pending, "a placed one gets its context job like a new Margin")
        XCTAssertEqual(p.podcastAnchorEvidenceCaptureStatus, .unavailable)
        XCTAssertNil(p.podcastAnchorEvidence)
        XCTAssertEqual(p.movedOrigin?.placeSource, "savedRun")

        let u = try XCTUnwrap(byId["ij-moved-u"])
        XCTAssertFalse(u.hasPlace)
        XCTAssertNil(u.anchor.mediaTimeMs)
        XCTAssertEqual(u.anchor.anchorType, .media)
        XCTAssertEqual(u.roughPercent, 0)
        XCTAssertEqual(u.transcriptionStatus, "pending", "the item's transcription job picks it up")
        XCTAssertEqual(u.anchorContextStatus, .ready, "no context job without a place")

        let w = try XCTUnwrap(byId["ij-moved-w"])
        XCTAssertEqual(w.captureKind, .written)
        XCTAssertEqual(w.transcript, "Typed note")
        XCTAssertEqual(w.displayText, "Typed note")
        XCTAssertEqual(w.audioStatus, "discarded")
        XCTAssertNil(w.audioPath)

        let origin = try XCTUnwrap(u.movedOrigin)
        XCTAssertEqual(origin.liveMarginId, "u")
        XCTAssertEqual(origin.fromLiveSessionId, "quick-1")
        XCTAssertEqual(origin.fromLiveSessionTitle, "Quick session")
        XCTAssertFalse(origin.placeKnown)
        XCTAssertEqual(origin.spokenOn, "watch")
        XCTAssertEqual(origin.clockNote, "Watch clock 2.0 s ahead, corrected")
        XCTAssertEqual(origin.durationMs, 3_000)
        XCTAssertEqual(origin.movedAt.timeIntervalSince1970, at(500).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(byId["ij-moved-w"]?.movedOrigin?.filingNote, LiveSessionFiling.afterEndNote)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "no file is touched")
    }

    // MARK: The item's session is never written (Design 6, starting states)

    func testTheItemsSessionIsUnchangedInEveryStartingState() throws {
        let states: [(String, Session)] = [
            ("in progress", session(for: "ep")),
            ("at 99%", session(for: "ep", percent: 99, resumeMs: 594_000)),
            ("finished", session(for: "ep", status: "finished", phase: .finished, percent: 100, resumeMs: 599_000)),
        ]
        for (name, before) in states {
            try setUpWithError()
            try seed(episode(), before)
            let stored = try XCTUnwrap(try store.loadSession(id: before.id))
            _ = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1, hint: .init(itemId: "ep", positionMs: 5_000, source: .playerRun))]),
                                           repository: store)
            XCTAssertEqual(try store.loadSession(id: before.id), stored, name)
            XCTAssertEqual(try store.loadSessions(itemId: "ep").count, 1, "\(name): no sibling session")
        }
    }

    func testAPlayingItemAndAFriendsHeardMarginsAreLeftAlone() throws {
        try seed(episode(), session(for: "ep"))
        try seed(episode(id: "other"), session(for: "other", resumeMs: 33_000))
        let friend = Interjection(
            id: "friend-1", itemId: "ep", sessionId: "s-ep", targetType: .item, targetId: "ep", createdAt: at(-10), roughPercent: 40,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 240_000),
            audioPath: nil, audioStatus: "discarded", transcriptionStatus: "transcribed", transcript: "Mine", cleanedTranscript: nil,
            displayText: "Mine", status: "active", captureKind: .written)
        try store.saveInterjection(friend)
        let otherBefore = try store.loadSession(id: "s-other")
        _ = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1)]), repository: store)
        XCTAssertEqual(try store.loadSession(id: "s-other"), otherBefore, "what plays elsewhere keeps its place")
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep").first { $0.id == "friend-1" }, friend)
    }

    // MARK: All or nothing, once

    func testASecondExecuteWritesNoSecondCopy() throws {
        try seed(episode(), session(for: "ep"))
        let moving = try plan([spoken("a", at: 1), spoken("b", at: 2)])
        let first = try LiveMarginMove.execute(plan: moving, repository: store)
        let second = try LiveMarginMove.execute(plan: moving, repository: store)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep").count, 2)
        XCTAssertEqual(try store.loadMovedMarginOrigins().count, 2)
    }

    func testAFailurePartWayLeavesNothing() throws {
        try seed(episode(), session(for: "ep"))
        // The app dying after the first Margin is written: the hook throws inside the transaction.
        XCTAssertThrowsError(try LiveMarginMove.execute(
            plan: try plan([spoken("a", at: 1), spoken("b", at: 2)]), repository: store, movedAt: at(9),
            afterEachWrite: { if $0 == 1 { throw SessionKitError.persistenceFailed("stopped") } }))
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep"), [], "the transaction rolled back the first Margin too")
        XCTAssertEqual(try store.loadMovedMarginOrigins(), [])
    }

    func testAnItemDeletedForGoodAfterThePlanTakesNothing() throws {
        try seed(episode(), session(for: "ep"))
        let moving = try plan([spoken("a", at: 1)])
        try store.deleteItem(id: "ep")
        XCTAssertThrowsError(try LiveMarginMove.execute(plan: moving, repository: store))
        XCTAssertEqual(try store.loadMovedMarginOrigins(), [])
    }

    /// Design 5, `store`: the move commits while another connection holds a read open.
    func testTheMoveCommitsWhileAReadIsOpen() throws {
        try seed(episode(), session(for: "ep"))
        let reader = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        XCTAssertEqual(try reader.loadSessions(itemId: "ep").count, 1)
        _ = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1)]), repository: store)
        XCTAssertEqual(try reader.loadInterjections(sessionId: "s-ep").count, 1)
    }

    // MARK: Undo

    func testUndoTakesThemOffAndKeepsTheRecording() throws {
        try seed(episode(), session(for: "ep"))
        let audio = directory.appending(path: "a.m4a")
        try Data("voice".utf8).write(to: audio)
        let moved = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1)]), repository: store)
        XCTAssertFalse(LiveMarginMove.listenerChanged(moved, repository: store))
        let words = try LiveMarginMove.undoItemSide(moved, repository: store)
        XCTAssertEqual(words, [:], "not transcribed yet")
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep"), [])
        XCTAssertEqual(try store.loadMovedMarginOrigins(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertNoThrow(try LiveMarginMove.undoItemSide(moved, repository: store), "a second Undo does nothing")
    }

    func testUndoCarriesBackWordsATranscriptionFoundMeanwhile() throws {
        try seed(episode(), session(for: "ep"))
        let moved = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1)]), repository: store)
        _ = try store.updateInterjection(id: moved[0].id, sessionId: "s-ep") {
            $0.transcript = "Heard later"
            $0.transcriptionStatus = "transcribed"
        }
        XCTAssertFalse(LiveMarginMove.listenerChanged(moved, repository: store), "a transcription finishing is not the listener's change")
        XCTAssertEqual(try LiveMarginMove.undoItemSide(moved, repository: store), ["a": "Heard later"])
    }

    func testUndoIsRefusedAfterTheListenerChangedAMovedMargin() throws {
        let changes: [(String, (inout Interjection) -> Void)] = [
            ("deleted", { $0.status = "deleted" }),
            ("starred", { $0.isStarredForSharing = true }),
            ("private note", { $0.privateSharingNote = "for Sam" }),
            ("shared", { $0.sharedAs = [MarginPacketIdentity(packageDigest: "d", packageScopedId: "x")] }),
            ("edited words", { $0.displayText = "My own words" }),
            ("tidy answered", { $0.tidyDecision = MarginTidyDecision(choice: .keptOriginal, decidedAt: Date(timeIntervalSince1970: 1)) }),
            ("Paper note role", { $0.paperRole = .purpose }),
        ]
        for (name, change) in changes {
            try setUpWithError()
            try seed(episode(), session(for: "ep"))
            let moved = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1, words: "Said")]), repository: store)
            _ = try store.updateInterjection(id: moved[0].id, sessionId: "s-ep", change)
            XCTAssertTrue(LiveMarginMove.listenerChanged(moved, repository: store), name)
        }
        // A context job finishing is not the listener's change.
        try setUpWithError()
        try seed(episode(), session(for: "ep"))
        let moved = try LiveMarginMove.execute(
            plan: try plan([spoken("a", at: 1, words: "Said", hint: .init(itemId: "ep", positionMs: 1_000, source: .playerRun))]), repository: store)
        _ = try store.updateInterjection(id: moved[0].id, sessionId: "s-ep") {
            $0.anchorContextStatus = .ready
            $0.anchor.anchorBefore = "before"
        }
        XCTAssertFalse(LiveMarginMove.listenerChanged(moved, repository: store))
    }

    /// Every field a Margin has is either one Undo compares or one listed as not the listener's, so a field added later
    /// (as `paperRole` was) can't be edited on the item and then lost to an Undo unnoticed.
    func testEveryMarginFieldIsSortedForUndo() throws {
        try seed(episode(), session(for: "ep"))
        let moved = try LiveMarginMove.execute(plan: try plan([spoken("a", at: 1)]), repository: store)
        let fields = Set(Mirror(reflecting: moved[0]).children.compactMap(\.label).map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 })
        let compared = Set(LiveMarginMove.listenerEdits.map(\.field))
        let notEdited = Set(LiveMarginMove.fieldsTheListenerDoesNotEdit.keys)
        XCTAssertEqual(compared.intersection(notEdited), [])
        XCTAssertEqual(fields.subtracting(compared).subtracting(notEdited), [],
                       "a new Margin field: add it to LiveMarginMove.listenerEdits if the listener can change it, else to fieldsTheListenerDoesNotEdit")
        XCTAssertEqual(compared.union(notEdited).subtracting(fields), [], "a listed field the Margin no longer has")
    }

    func testAPaperNoteRoleSetOnAMovedMarginRefusesUndoAndKeepsTheRows() async throws {
        let (plan, moved, files) = try await movedWithLiveSide([spoken("a", at: 1), spoken("b", at: 2)])
        _ = try store.updateInterjection(id: moved[0].id, sessionId: "s-ep") { $0.paperRole = .purpose }
        let outcome = await LiveMarginMove.undo(plan: plan, moved: moved, repository: store, files: files)
        XCTAssertEqual(outcome, .refused(.changedOnItem(title: plan.itemTitle)))
        let rows = try store.loadInterjections(sessionId: "s-ep")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == moved[0].id }?.paperRole, .purpose)
    }

    // MARK: Undo's order (audit on #5172): the live side first, the item rows last

    /// A moved Margin and the live session it left, on real files beside the store.
    private func movedWithLiveSide(_ margins: [LiveSessionMargin]) async throws -> (LiveMarginMove.Plan, [Interjection], LiveSessionFileWorker) {
        try seed(episode(), session(for: "ep"))
        let live = quick(margins)
        let root = directory.appending(path: "support", directoryHint: .isDirectory)
        try LiveSessionCollection(root: root).save(live)
        let files = LiveSessionFileWorker(root: root)
        let plan = try LiveMarginMove.plan(margins: margins, session: live, itemId: "ep", repository: store)
        let moved = try LiveMarginMove.execute(plan: plan, repository: store)
        _ = try await files.removeMovedMargins(ids: plan.liveMarginIds, fromSession: live.id)
        return (plan, moved, files)
    }

    func testUndoPutsTheLiveMarginsBackThenTakesTheItemRows() async throws {
        let (plan, moved, files) = try await movedWithLiveSide([spoken("a", at: 1), spoken("b", at: 2)])
        _ = try store.updateInterjection(id: moved[0].id, sessionId: "s-ep") { $0.transcript = "Heard later" }
        let outcome = await LiveMarginMove.undo(plan: plan, moved: moved, repository: store, files: files)
        XCTAssertEqual(outcome, .putBack(count: 2))
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep"), [])
        let back = await files.session(id: "quick-1")
        XCTAssertEqual(back?.margins.map(\.id).sorted(), ["a", "b"])
        XCTAssertEqual(back?.margins.first { $0.id == "a" }?.text, "Heard later", "words found meanwhile come back")
    }

    func testAFailedRestoreLeavesTheItemRows() async throws {
        let (plan, moved, files) = try await movedWithLiveSide([spoken("a", at: 1), spoken("b", at: 2)])
        // The session's file can't be written: a non-empty folder sits where it goes.
        let file = LiveSessionCollection(root: directory.appending(path: "support", directoryHint: .isDirectory)).url(for: "quick-1")
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.appending(path: "blocker", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let outcome = await LiveMarginMove.undo(plan: plan, moved: moved, repository: store, files: files)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep").map(\.id).sorted(), moved.map(\.id).sorted(),
                       "the Margins are still on the item, never in neither place")
        XCTAssertEqual(try store.loadMovedMarginOrigins().count, 2)
    }

    func testARefusalOnTheWayLeavesTheItemRows() async throws {
        let (plan, moved, files) = try await movedWithLiveSide([spoken("a", at: 1), spoken("b", at: 2)])
        _ = try store.updateInterjection(id: moved[0].id, sessionId: "s-ep") { $0.isStarredForSharing = true }
        let outcome = await LiveMarginMove.undo(plan: plan, moved: moved, repository: store, files: files)
        XCTAssertEqual(outcome, .refused(.changedOnItem(title: plan.itemTitle)))
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep").count, 2)
        let session = await files.session(id: "quick-1")
        XCTAssertTrue(session?.margins.isEmpty ?? true, "nothing came back to the session")
    }

    func testAWatchWithdrawAfterTheMoveDeletesTheMovedMargin() throws {
        try seed(episode(), session(for: "ep"))
        let margin = spoken("a", at: 1)
        _ = try LiveMarginMove.execute(plan: try plan([margin]), repository: store)
        let touched = PlayerItemMargin.withdraw(audioPath: margin.audioPath!, in: try store.loadSessions(), repository: store) { found in
            try store.updateInterjection(id: found.id, sessionId: found.sessionId) { $0.status = "deleted" } != nil
        }
        XCTAssertEqual(touched, ["ep"])
        XCTAssertEqual(try store.loadInterjections(sessionId: "s-ep").first?.status, "deleted")
    }
}
