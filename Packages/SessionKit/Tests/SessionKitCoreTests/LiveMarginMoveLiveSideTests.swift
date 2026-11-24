import Foundation
import XCTest
@testable import SessionKit

/// #4233 Design 6c: the live side of a move, on real files in a temporary Application Support stand-in. Moved Margins
/// leave their session and a late Watch copy is refused; an unrenamed Quick session the move empties goes the way `tidy`
/// removes one; Undo puts them back, recreating the session if needed; a move cut short is finished at launch; and a
/// permanent delete keeps a recording a live session still names.
final class LiveMarginMoveLiveSideTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-move-side-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func spoken(_ id: String, at offset: TimeInterval) -> LiveSessionMargin {
        LiveSessionMargin(id: id, text: "", markedAt: at(offset), audioPath: "SpokenMargins/interjections/\(id).m4a", durationMs: 2_000, spokenOn: "watch")
    }

    private func quick(_ margins: [LiveSessionMargin], id: String = "quick-1", title: String = "Quick session") -> LiveSession {
        var session = LiveSession(id: id, title: title, startedAt: margins.first!.markedAt, isQuick: true)
        for margin in margins { session.add(margin) }
        return session
    }

    private func stored(_ sessions: [LiveSession]) async throws -> LiveSessionFileWorker {
        let collection = LiveSessionCollection(root: root)
        for session in sessions { try collection.save(session) }
        return LiveSessionFileWorker(root: root)
    }

    // MARK: Removal

    func testMovedMarginsLeaveTheSessionAndALateWatchCopyIsRefused() async throws {
        let worker = try await stored([quick([spoken("a", at: 10), spoken("b", at: 20), spoken("c", at: 30)])])
        let removal = try await worker.removeMovedMargins(ids: ["a", "b"], fromSession: "quick-1")
        XCTAssertEqual(removal?.removedIds, ["a", "b"])
        XCTAssertEqual(removal?.removedSession, false)
        XCTAssertEqual(removal?.session?.margins.map(\.id), ["c"])
        let summaries = await worker.summaries(now: at(100))
        XCTAssertEqual(summaries.first?.marginCount, 1, "the Library's Live row and the Live Activity count what's left")

        let deletions = await worker.currentDeletions()
        XCTAssertTrue(deletions.marginIds.isSuperset(of: ["a", "b"]))
        XCTAssertFalse(deletions.deletedSession("quick-1"))
        let decision = LiveSessionFiling.decide(
            .init(marginId: "a", markedAt: at(10)), sessions: [], deletions: deletions, playerRuns: [], now: at(100))
        XCTAssertEqual(decision, .rejected(.marginDeleted))

        // A stale screen save that still has them doesn't bring them back.
        let stale = quick([spoken("a", at: 10), spoken("b", at: 20), spoken("c", at: 30)])
        try await worker.save(stale, generation: 1)
        let reloaded = await worker.session(id: "quick-1")
        XCTAssertEqual(reloaded?.margins.map(\.id), ["c"])
    }

    func testAnEmptiedUnrenamedQuickSessionGoesWithNoSpanInDeletions() async throws {
        let worker = try await stored([quick([spoken("a", at: 10), spoken("b", at: 20)])])
        let removal = try await worker.removeMovedMargins(ids: ["a", "b"], fromSession: "quick-1")
        XCTAssertEqual(removal?.removedSession, true)
        XCTAssertNil(removal?.session)
        let gone = await worker.session(id: "quick-1")
        XCTAssertNil(gone)
        let deletions = await worker.currentDeletions()
        XCTAssertTrue(deletions.sessions.isEmpty, "a discard-style span would refuse later Margins in that time")
        XCTAssertNil(LiveSessionCollection(root: root).loadAll().first { $0.id == "quick-1" }, "its file is gone")

        // A later Watch Margin taken inside the old span still files.
        let decision = LiveSessionFiling.decide(
            .init(marginId: "late", markedAt: at(15)), sessions: [], deletions: deletions, playerRuns: [], now: at(100))
        XCTAssertEqual(decision, .newQuick)
    }

    func testARenamedOrNamedSessionStaysEmpty() async throws {
        var named = LiveSession(id: "meeting", kind: .meeting, title: "", startedAt: at(0), endedAt: at(60))
        named.add(spoken("m", at: 5))
        let worker = try await stored([quick([spoken("a", at: 100)], title: "Book club"), named])
        let renamed = try await worker.removeMovedMargins(ids: ["a"], fromSession: "quick-1")
        XCTAssertEqual(renamed?.removedSession, false)
        XCTAssertEqual(renamed?.session?.title, "Book club")
        let meeting = try await worker.removeMovedMargins(ids: ["m"], fromSession: "meeting")
        XCTAssertEqual(meeting?.removedSession, false)
        let kept = await worker.session(id: "meeting")
        XCTAssertEqual(kept?.margins, [])
    }

    func testRecordingFilesAreNeverDeleted() async throws {
        let file = root.appending(path: "SpokenMargins/interjections/a.m4a")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("voice".utf8).write(to: file)
        let worker = try await stored([quick([spoken("a", at: 10)])])
        _ = try await worker.removeMovedMargins(ids: ["a"], fromSession: "quick-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Undo

    func testUndoPutsThemBackIntoAnExistingSession() async throws {
        let before = quick([spoken("a", at: 10), spoken("b", at: 20)])
        let worker = try await stored([before])
        _ = try await worker.removeMovedMargins(ids: ["a"], fromSession: "quick-1")
        let outcome = try await worker.restoreMovedMargins([before.margins[0]], into: before)
        guard case let .restored(session) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(session.margins.map(\.id), ["a", "b"])
        let deletions = await worker.currentDeletions()
        XCTAssertFalse(deletions.marginIds.contains("a"))
        let again = try await worker.restoreMovedMargins([before.margins[0]], into: before)
        guard case let .restored(twice) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(twice.margins.map(\.id), ["a", "b"], "two Undos give one restore")
    }

    func testUndoRecreatesASessionTheMoveRemoved() async throws {
        let before = quick([spoken("a", at: 10), spoken("b", at: 20)])
        let worker = try await stored([before])
        _ = try await worker.removeMovedMargins(ids: ["a", "b"], fromSession: "quick-1")
        let outcome = try await worker.restoreMovedMargins(before.margins, into: before)
        guard case let .restored(session) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(session.id, "quick-1")
        XCTAssertEqual(session.title, "Quick session")
        XCTAssertEqual(session.isQuick, true)
        XCTAssertEqual(session.margins.map(\.id), ["a", "b"])
        XCTAssertEqual(session.startedAt, at(10))
        XCTAssertEqual(session.endedAt, at(20))
        let reloaded = LiveSessionCollection(root: root).loadAll().first { $0.id == "quick-1" }
        XCTAssertEqual(reloaded?.margins.map(\.id), ["a", "b"], "written to disk")
    }

    func testUndoIsRefusedAfterADiscardOrASave() async throws {
        let before = quick([spoken("a", at: 10), spoken("b", at: 20)])
        let worker = try await stored([before])
        _ = try await worker.removeMovedMargins(ids: ["a"], fromSession: "quick-1")
        await worker.markSaved(sessionId: "quick-1", itemId: "notes")
        let saved = try await worker.restoreMovedMargins([before.margins[0]], into: before)
        XCTAssertEqual(saved, .savedAsNotes)

        let other = quick([spoken("x", at: 1_000), spoken("y", at: 1_010)], id: "quick-2")
        let worker2 = try await stored([other])
        _ = try await worker2.removeMovedMargins(ids: ["x"], fromSession: "quick-2")
        await worker2.discard(sessionId: "quick-2", generation: 1)
        let discarded = try await worker2.restoreMovedMargins([other.margins[0]], into: other)
        XCTAssertEqual(discarded, .discarded)
        let deletions = await worker2.currentDeletions()
        XCTAssertTrue(deletions.marginIds.contains("x"), "nothing changed")
    }

    // MARK: Recovery

    func testAMoveCutShortIsFinishedAtLaunch() async throws {
        let before = quick([spoken("a", at: 10), spoken("b", at: 20), spoken("c", at: 30)])
        _ = try await stored([before])
        // The item side was written for a and b, then the app died. A new worker over the same folder:
        let relaunched = LiveSessionFileWorker(root: root)
        let touched = await relaunched.reconcileMovedMargins(liveMarginIds: ["a", "b", "not-here"])
        XCTAssertEqual(touched, ["quick-1"])
        let session = await relaunched.session(id: "quick-1")
        XCTAssertEqual(session?.margins.map(\.id), ["c"], "never in both places")
        let nothing = await relaunched.reconcileMovedMargins(liveMarginIds: ["a", "b"])
        XCTAssertEqual(nothing, [], "a second pass finds nothing")
    }

    func testANewMarginFiledDuringAMoveStaysInTheSession() async throws {
        let worker = try await stored([quick([spoken("a", at: 10)])])
        // A Watch Margin is filed into the session between the plan and the removal.
        let newcomer = LiveSessionMargin(id: "new", text: "", markedAt: at(12), audioPath: "SpokenMargins/interjections/new.m4a")
        _ = await worker.update(marginId: "a") { session in
            session.add(newcomer)
            return true
        }
        let removal = try await worker.removeMovedMargins(ids: ["a"], fromSession: "quick-1")
        XCTAssertEqual(removal?.removedSession, false)
        XCTAssertEqual(removal?.session?.margins.map(\.id), ["new"])
    }

    // MARK: Recordings (Design 2.9.3)

    func testAPermanentDeleteKeepsARecordingALiveSessionNames() throws {
        let support = root!
        let file = support.appending(path: "SpokenMargins/interjections/a.m4a")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("voice".utf8).write(to: file)
        try LiveSessionCollection(root: support).save(quick([spoken("a", at: 10)]))

        // Moved, undone, then the item purged: the item's row named the same recording.
        let named = LiveSessionCollection(root: support).namedAudioPaths()
        XCTAssertEqual(named, ["SpokenMargins/interjections/a.m4a"])
        let removed = MarginRecordingCleanup.removeFiles(
            deletedAudioPaths: ["SpokenMargins/interjections/a.m4a"], survivingAudioPaths: Array(named),
            within: support.appending(path: "SpokenMargins"), resolve: { support.appending(path: $0) })
        XCTAssertEqual(removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Without the live session's names the same delete would have taken it: the case this guards.
        XCTAssertEqual(MarginRecordingCleanup.filesToRemove(
            deletedAudioPaths: ["SpokenMargins/interjections/a.m4a"], survivingAudioPaths: [],
            within: support.appending(path: "SpokenMargins"), resolve: { support.appending(path: $0) }).count, 1)
    }
}
