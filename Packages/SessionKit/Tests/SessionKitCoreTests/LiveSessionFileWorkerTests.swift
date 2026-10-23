import Foundation
import XCTest
@testable import SessionKit

/// #2487, #2256: the live session's disk work runs on `LiveSessionFileWorker`, off the main thread. These use real
/// files in a temporary Application Support stand-in.
final class LiveSessionFileWorkerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-worker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dropInInbox(_ worker: LiveSessionFileWorker, id: String, at offset: TimeInterval) throws -> WatchMarginTransfer {
        let transfer = WatchMarginTransfer(id: id, wallStart: t0.addingTimeInterval(offset), durationMs: 2_000)
        let received = root.appending(path: "received-\(id).m4a")
        try Data("audio-\(id)".utf8).write(to: received)
        try worker.storeIncoming(fileAt: received, transfer: transfer)
        return transfer
    }

    func testAnOlderSaveArrivingLateNeverOverwritesANewerOne() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let newer = LiveSession(id: "live", title: "newer", startedAt: t0)
        let older = LiveSession(id: "live", title: "older", startedAt: t0)
        let wroteNewer = try await worker.save(newer, generation: 2)
        let wroteOlder = try await worker.save(older, generation: 1)
        XCTAssertTrue(wroteNewer)
        XCTAssertFalse(wroteOlder)
        let loaded = await worker.load()
        XCTAssertEqual(loaded?.title, "newer")
    }

    func testAStaleSaveDoesNotBringBackADiscardedSession() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 1)
        await worker.discard(sessionId: "live", generation: 3)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 2)
        let loaded = await worker.load()
        XCTAssertNil(loaded)
    }

    func testAWatchMarginIsFiledOnceAndItsRecordingMovedIntoPlace() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 1)
        let transfer = try dropInInbox(worker, id: "abc", at: 30)

        let filed = await worker.fileWatchInbox(now: t0.addingTimeInterval(60))
        XCTAssertEqual(filed.filed, [.init(marginId: transfer.marginId, audioPath: transfer.audioPath)])
        XCTAssertEqual(filed.answers.map(\.outcome), [.filed])
        XCTAssertEqual(filed.answers.first?.receipt.status, .stored)
        XCTAssertEqual(filed.answers.first?.sessionId, "live")
        let destination = try XCTUnwrap(worker.recordingURL(for: transfer.audioPath))
        XCTAssertEqual(try Data(contentsOf: destination), Data("audio-abc".utf8))
        let inbox = try XCTUnwrap(worker.inboxDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
        let stored = await worker.load()
        XCTAssertEqual(stored?.margins.map(\.id), [transfer.marginId])

        _ = try dropInInbox(worker, id: "abc", at: 30) // WatchConnectivity delivered it again
        let again = await worker.fileWatchInbox(now: t0.addingTimeInterval(60))
        XCTAssertEqual(again.filed, [])
        XCTAssertEqual(again.answers.map(\.outcome), [.alreadyFiled])
        XCTAssertEqual(again.answers.first?.receipt.status, .duplicate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
        let storedAgain = await worker.load()
        XCTAssertEqual(storedAgain?.margins.count, 1)
    }

    /// Slice 1a: the hidden inbox goes. A Watch Margin with no session makes a quick session the listener can see,
    /// instead of waiting unseen for the next session (what build dbaa231 did).
    func testAWatchMarginWithNoSessionMakesAQuickSessionInsteadOfWaiting() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "q1" })
        let transfer = try dropInInbox(worker, id: "early", at: 0)
        let pass = await worker.fileWatchInbox(now: t0.addingTimeInterval(5))
        XCTAssertEqual(pass.filed.map(\.marginId), [transfer.marginId])
        XCTAssertEqual(pass.answers.first?.filedIn, "a quick session")
        let inbox = try XCTUnwrap(worker.inboxDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
        let quick = await worker.session(id: "quick-q1")
        XCTAssertEqual(quick?.isQuick, true)
        XCTAssertEqual(quick?.margins.map(\.id), [transfer.marginId])
        let rows = await worker.summaries(now: t0.addingTimeInterval(5))
        XCTAssertEqual(rows.map(\.id), ["quick-q1"])
        // A quick session never goes into current.json, which the build before this one would show as running.
        XCTAssertNil(LiveSessionStore.load(from: root))
    }

    /// The screen saves its own copy, which can't yet hold a Watch Margin or transcript the worker just filed.
    /// That save must not drop them before the screen takes them in.
    func testAScreenSaveRacingTheReconcileKeepsTheWatchMarginAndItsWords() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let screen = LiveSession(id: "live", startedAt: t0, margins: [LiveSessionMargin(id: "typed", text: "hi", markedAt: t0)])
        try await worker.save(screen, generation: 1)
        let transfer = try dropInInbox(worker, id: "w1", at: 10)
        _ = await worker.fileWatchInbox(now: t0.addingTimeInterval(60))
        let id = transfer.marginId
        await worker.update(marginId: id) { $0.setTranscript("spoken words", forMarginId: id) }

        try await worker.save(screen, generation: 2) // the screen's copy, without the Watch Margin
        let stored = await worker.load()
        XCTAssertEqual(stored?.margins.map(\.id), ["typed", transfer.marginId])
        XCTAssertEqual(stored?.margins.last?.text, "spoken words")

        // Once the screen's copy carries the Margin, the listener's own changes win.
        var tookIn = try XCTUnwrap(stored)
        tookIn.margins.removeAll { $0.id == transfer.marginId }
        try await worker.save(try XCTUnwrap(stored), generation: 3)
        try await worker.save(tookIn, generation: 4)
        let afterRemove = await worker.load()
        XCTAssertEqual(afterRemove?.margins.map(\.id), ["typed"])
    }

    /// Build dbaa231: with any stored session, even an ended one, every Watch Margin went into it. Slice 1a check 4: an
    /// hour after the meeting ended, a Watch Margin makes a new quick session, not the meeting.
    func testAWatchMarginAnHourAfterTheMeetingEndedDoesNotGoIntoIt() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "later" })
        try await worker.save(LiveSession(id: "meet", startedAt: t0, endedAt: t0.addingTimeInterval(1_800)), generation: 1)
        let transfer = try dropInInbox(worker, id: "hour-later", at: 1_800 + 3_600)
        let pass = await worker.fileWatchInbox(now: t0.addingTimeInterval(1_800 + 3_700))
        XCTAssertEqual(pass.answers.first?.sessionId, "quick-later")
        let meeting = await worker.session(id: "meet")
        XCTAssertEqual(meeting?.margins, [])
        let quick = await worker.session(id: "quick-later")
        XCTAssertEqual(quick?.margins.map(\.id), [transfer.marginId])
    }

    func testAWatchMarginWhileOurPlayerPlaysIsHandedBackForTheItem() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let transfer = try dropInInbox(worker, id: "pod", at: 100)
        let run = LiveSessionFiling.PlayerRun(itemId: "ep", startedAt: t0, endedAt: t0.addingTimeInterval(200), startPositionMs: 5_000, rate: 1)
        let pass = await worker.fileWatchInbox(playerRuns: [run], now: t0.addingTimeInterval(200))
        XCTAssertEqual(pass.placements.map(\.itemId), ["ep"])
        XCTAssertEqual(pass.placements.first?.positionMs, 105_000)
        XCTAssertEqual(pass.placements.first?.audioPath, transfer.audioPath)
        let destination = try XCTUnwrap(worker.recordingURL(for: transfer.audioPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "the recording is in place before the item takes it")
        let sessions = await worker.allSessions()
        XCTAssertEqual(sessions, [])

        // The item couldn't take it: it files by the rest of the rule instead of being lost.
        let filed = await worker.fileAsQuick(try XCTUnwrap(pass.placements.first), now: t0.addingTimeInterval(200))
        XCTAssertTrue(filed)
        let after = await worker.allSessions()
        XCTAssertEqual(after.flatMap(\.margins).map(\.audioPath), [transfer.audioPath])
    }

    func testAWatchMarginForADeletedSessionIsRefusedAndNotBroughtBack() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "meet", startedAt: t0, endedAt: t0.addingTimeInterval(600)), generation: 1)
        await worker.discard(sessionId: "meet", generation: 2)
        _ = try dropInInbox(worker, id: "late-copy", at: 300)
        let pass = await worker.fileWatchInbox(now: t0.addingTimeInterval(900))
        XCTAssertEqual(pass.answers.map(\.outcome), [.rejected])
        XCTAssertEqual(pass.answers.first?.reason, LiveSessionFiling.RejectReason.sessionDeleted.words)
        let sessions = await worker.allSessions()
        XCTAssertEqual(sessions, [])
        // The same recording again is still refused, not filed.
        _ = try dropInInbox(worker, id: "late-copy", at: 300)
        let again = await worker.fileWatchInbox(now: t0.addingTimeInterval(900))
        XCTAssertEqual(again.answers.map(\.outcome), [.alreadyFiled])
        let stillNone = await worker.allSessions()
        XCTAssertEqual(stillNone, [])
    }

    func testADeletedMarginIsNotBroughtBackByALateCopy() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live", startedAt: t0), generation: 1)
        let transfer = try dropInInbox(worker, id: "w", at: 10)
        _ = await worker.fileWatchInbox(now: t0.addingTimeInterval(20))
        let loadedLive = await worker.session(id: "live")
        var screen = try XCTUnwrap(loadedLive)
        screen.margins.removeAll()
        await worker.forgetMargin(id: transfer.marginId)
        try await worker.save(screen, generation: 2)
        // A second copy on the sure lane arrives after a reinstall cleared the inbox's record.
        try? FileManager.default.removeItem(at: try XCTUnwrap(worker.receivedDirectory))
        let fresh = LiveSessionFileWorker(root: root)
        _ = try dropInInbox(fresh, id: "w", at: 10)
        let pass = await fresh.fileWatchInbox(now: t0.addingTimeInterval(30))
        XCTAssertEqual(pass.answers.map(\.outcome), [.rejected])
        let live = await fresh.session(id: "live")
        XCTAssertEqual(live?.margins, [])
    }

    /// Slice 1a point 7: Lock Screen Marks with no session file by the rule instead of waiting to be thrown away.
    func testLockScreenMarksFileByTheRule() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "marks" })
        try await worker.save(LiveSession(id: "meet", startedAt: t0, endedAt: t0.addingTimeInterval(600)), generation: 1)
        _ = await worker.fileMarks([t0.addingTimeInterval(60), t0.addingTimeInterval(5_000)], now: t0.addingTimeInterval(5_000))
        let meeting = await worker.session(id: "meet")
        XCTAssertEqual(meeting?.margins.map(\.isBlindMark), [true])
        let quick = await worker.session(id: "quick-marks")
        XCTAssertEqual(quick?.margins.map(\.markedAt), [t0.addingTimeInterval(5_000)])
        // Draining the same Mark twice files it once.
        _ = await worker.fileMarks([t0.addingTimeInterval(60)], now: t0.addingTimeInterval(5_000))
        let again = await worker.session(id: "meet")
        XCTAssertEqual(again?.margins.count, 1)
    }

    func testAScreenSaveOfAQuickSessionDoesNotUndoAMerge() async throws {
        let worker = LiveSessionFileWorker(root: root, makeId: { "a" })
        _ = await worker.fileMarks([t0], now: t0)
        let loadedQuick = await worker.session(id: "quick-a")
        let screenCopy = try XCTUnwrap(loadedQuick)
        // A named session covering the Mark arrives (the Watch's out-of-range session): the quick Mark moves into it.
        try await worker.save(LiveSession(id: "meet", startedAt: t0.addingTimeInterval(-60), endedAt: t0.addingTimeInterval(60)), generation: 1)
        _ = await worker.fileMarks([], now: t0.addingTimeInterval(120))
        let moved = await worker.session(id: "meet")
        XCTAssertEqual(moved?.margins.first?.filingNote, LiveSessionFiling.movedFromQuickNote)
        // The screen still showing the quick session saves its stale copy: the Mark is not duplicated back.
        try await worker.save(screenCopy, generation: 1)
        let quick = await worker.session(id: "quick-a")
        XCTAssertNil(quick)
    }
}
