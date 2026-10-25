import Foundation
import XCTest
@testable import SessionKit

/// #2487 slice 1b: the phone's side of the Watch contract, on the real file worker with real files. Sessions the
/// Watch starts, ends and resumes; Margins that name them, with the Watch's clock two minutes off; "hello"; and the
/// phone ending a session the Watch started.
final class LiveSessionWatchContractWorkerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-contract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func envelope(_ message: WatchMessage, sentAt offset: TimeInterval = 0, clock: WatchClockStamp? = nil) -> WatchEnvelope {
        WatchEnvelope(seq: 1, sentAt: t0.addingTimeInterval(offset), clock: clock, message: message)
    }

    private func watchSession(_ id: String = "live-w", kind: WatchSessionKind = .meeting, at offset: TimeInterval = 0) -> WatchSessionInfo {
        WatchSessionInfo(id: id, kind: kind, title: kind.label, owner: .watch, startedAt: t0.addingTimeInterval(offset))
    }

    @discardableResult
    private func deliver(_ worker: LiveSessionFileWorker, _ transfer: WatchMarginTransfer, bytes: String? = nil) throws -> WatchMarginTransfer {
        let received = root.appending(path: "received-\(transfer.id)-\(transfer.attempt).m4a")
        try Data((bytes ?? "audio-\(transfer.id)").utf8).write(to: received)
        try worker.storeIncoming(fileAt: received, transfer: transfer)
        return transfer
    }

    private func sha(_ text: String) -> String {
        let url = root.appending(path: "sha-\(UUID().uuidString)")
        try? Data(text.utf8).write(to: url)
        return (try? WatchMarginFolderStore<WatchMarginInbox.Entry>.digest(of: url).sha256) ?? ""
    }

    // MARK: Owner check 3 and 4: start on the Watch, record during the call

    func testAWatchStartMakesARunningSessionAndItsMarginFilesIntoIt() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let reply = await worker.applyWatch(envelope(.sessionStart(watchSession())), now: t0.addingTimeInterval(1))
        XCTAssertEqual(reply.board.running?.id, "live-w")
        XCTAssertEqual(reply.board.running?.owner, .watch)
        XCTAssertEqual(reply.board.running?.kind, .meeting)
        XCTAssertEqual(reply.board.running?.title, "Meeting")
        let running = await worker.runningSession()
        XCTAssertEqual(running?.id, "live-w")
        XCTAssertEqual(running?.ownerDevice, "watch")

        let transfer = try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0.addingTimeInterval(70), durationMs: 2_000, sessionId: "live-w", sha256: sha("audio-m1")))
        let pass = await worker.fileWatchInbox(now: t0.addingTimeInterval(80))
        XCTAssertEqual(pass.answers.first?.outcome, .filed)
        XCTAssertEqual(pass.answers.first?.filedWords, "Filed in Meeting, about 1:10")
        let session = await worker.session(id: "live-w")
        XCTAssertEqual(session?.margins.map(\.id), [transfer.marginId])
    }

    func testAStartRepeatedOnTheSureLaneChangesNothing() async throws {
        let worker = LiveSessionFileWorker(root: root)
        _ = await worker.applyWatch(envelope(.sessionStart(watchSession())), now: t0)
        _ = await worker.applyWatch(envelope(.sessionEnd(id: "live-w", endedAt: t0.addingTimeInterval(60))), now: t0.addingTimeInterval(60))
        _ = await worker.applyWatch(envelope(.sessionStart(watchSession())), now: t0.addingTimeInterval(61))
        let session = await worker.session(id: "live-w")
        XCTAssertEqual(session?.endedAt, t0.addingTimeInterval(60), "a late copy of the start never reopens it")
    }

    // MARK: The clock: two minutes of skew

    func testAWatchTwoMinutesAheadFilesByTheCorrectedTimeAndKeepsTheRawOne() async throws {
        let worker = LiveSessionFileWorker(root: root)
        // A phone meeting from t0 to t0+600. The Watch, 120 s ahead, records at its t0+650 (the phone's t0+530).
        try await worker.save(LiveSession(id: "live-p", title: "Budget meeting", startedAt: t0, endedAt: t0.addingTimeInterval(600)), generation: 1)
        let clock = WatchClockStamp(offset: 120, measuredAt: t0.addingTimeInterval(500))
        try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0.addingTimeInterval(650), durationMs: 2_000, clock: clock))
        _ = await worker.fileWatchInbox(now: t0.addingTimeInterval(700))
        let read1 = await worker.session(id: "live-p")?.margins.first
        let margin = try XCTUnwrap(read1)
        XCTAssertEqual(margin.markedAt, t0.addingTimeInterval(530))
        XCTAssertEqual(margin.deviceMarkedAt, t0.addingTimeInterval(650), "the raw time is kept")
        XCTAssertEqual(margin.sessionOffsetMs, 530_000)
        XCTAssertEqual(margin.clockNote, "Watch clock 120.0 s ahead, corrected")
    }

    func testWithNoMeasurementTheWatchTimeIsUsedAsItIsAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0, durationMs: 2_000))
        _ = await worker.fileWatchInbox(now: t0)
        let read2 = await worker.allSessions().first?.margins.first
        let margin = try XCTUnwrap(read2)
        XCTAssertEqual(margin.markedAt, t0)
        XCTAssertEqual(margin.clockNote, "Watch clock, not checked")
        // A day-old measurement isn't used either.
        let worker2 = LiveSessionFileWorker(root: root.appending(path: "two"))
        try deliver(worker2, WatchMarginTransfer(id: "m2", wallStart: t0, durationMs: 2_000, clock: WatchClockStamp(offset: 120, measuredAt: t0.addingTimeInterval(-86_401))))
        _ = await worker2.fileWatchInbox(now: t0)
        let read3 = await worker2.allSessions().first?.margins.first
        let old = try XCTUnwrap(read3)
        XCTAssertEqual(old.markedAt, t0)
    }

    func testAWatchStartIsCorrectedByItsClockToo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let clock = WatchClockStamp(offset: -120, measuredAt: t0)
        _ = await worker.applyWatch(envelope(.sessionStart(watchSession(at: 0)), clock: clock), now: t0.addingTimeInterval(121))
        let session = await worker.session(id: "live-w")
        XCTAssertEqual(session?.startedAt, t0.addingTimeInterval(120), "the Watch was two minutes behind")
    }

    // MARK: Lanes out of order: the file before the start

    func testAMarginThatArrivesBeforeItsSessionsStartJoinsItWhenTheStartComes() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0.addingTimeInterval(30), durationMs: 2_000, sessionId: "live-w"))
        _ = await worker.fileWatchInbox(now: t0.addingTimeInterval(31))
        let placeholder = await worker.session(id: "live-w")
        XCTAssertEqual(placeholder?.margins.count, 1)
        _ = await worker.applyWatch(envelope(.sessionStart(watchSession(kind: .audiobook, at: 0))), now: t0.addingTimeInterval(40))
        let read4 = await worker.session(id: "live-w")
        let session = try XCTUnwrap(read4)
        XCTAssertNil(session.endedAt, "it runs")
        XCTAssertEqual(session.startedAt, t0)
        XCTAssertEqual(session.kind, .audiobook)
        XCTAssertEqual(session.margins.first?.sessionOffsetMs, 30_000)
        let board = await worker.watchBoard(now: t0.addingTimeInterval(41))
        XCTAssertEqual(board.running?.id, "live-w")
    }

    // MARK: Ending and resuming

    func testEndFromTheWatchEndsAPhoneSessionAndResumeReopensItWithinTenMinutes() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live-p", title: "Budget meeting", startedAt: t0), generation: 1)
        var reply = await worker.applyWatch(envelope(.sessionEnd(id: "live-p", endedAt: t0.addingTimeInterval(300)), sentAt: 300), now: t0.addingTimeInterval(301))
        XCTAssertNil(reply.board.running)
        XCTAssertEqual(reply.board.recentlyEnded?.id, "live-p")
        let read5 = await worker.session(id: "live-p")?.endedAt
        XCTAssertEqual(read5, t0.addingTimeInterval(300))

        reply = await worker.applyWatch(envelope(.sessionResume(id: "live-p"), sentAt: 400), now: t0.addingTimeInterval(401))
        XCTAssertEqual(reply.board.running?.id, "live-p")
        // The End's sure-lane copy arrives after the Resume: it doesn't end it again.
        reply = await worker.applyWatch(envelope(.sessionEnd(id: "live-p", endedAt: t0.addingTimeInterval(300)), sentAt: 300), now: t0.addingTimeInterval(402))
        XCTAssertEqual(reply.board.running?.id, "live-p")

        _ = await worker.applyWatch(envelope(.sessionEnd(id: "live-p", endedAt: t0.addingTimeInterval(500)), sentAt: 500), now: t0.addingTimeInterval(500))
        reply = await worker.applyWatch(envelope(.sessionResume(id: "live-p"), sentAt: 1_101), now: t0.addingTimeInterval(1_101))
        XCTAssertNil(reply.board.running, "more than ten minutes after the End")
    }

    func testResumeIsRefusedWhenAnotherSessionStartedSince() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try await worker.save(LiveSession(id: "live-p", startedAt: t0, endedAt: t0.addingTimeInterval(60)), generation: 1)
        _ = await worker.applyWatch(envelope(.sessionStart(watchSession(at: 90))), now: t0.addingTimeInterval(90))
        let reply = await worker.applyWatch(envelope(.sessionResume(id: "live-p"), sentAt: 100), now: t0.addingTimeInterval(100))
        XCTAssertEqual(reply.board.running?.id, "live-w")
    }

    // MARK: One session at a time

    func testThePhoneStartingASessionEndsTheOneTheWatchStartedAndSaysSo() async throws {
        let worker = LiveSessionFileWorker(root: root)
        _ = await worker.applyWatch(envelope(.sessionStart(WatchSessionInfo(id: "live-w", kind: .other, title: "Lecture", owner: .watch, startedAt: t0))), now: t0)
        try await worker.save(LiveSession(id: "live-p", title: "Budget meeting", startedAt: t0.addingTimeInterval(600)), generation: 1)
        let read6 = await worker.session(id: "live-w")
        let lecture = try XCTUnwrap(read6)
        XCTAssertEqual(lecture.endedAt, t0.addingTimeInterval(600))
        XCTAssertEqual(lecture.endReason, "replaced")
        let board = await worker.watchBoard(now: t0.addingTimeInterval(601))
        XCTAssertEqual(board.running?.id, "live-p")
        let note = try XCTUnwrap(board.endNotes["live-w"])
        XCTAssertTrue(note.hasPrefix("Lecture ended at "), note)
        XCTAssertTrue(note.hasSuffix(", when you started Budget meeting on iPhone"), note)
    }

    func testAWatchStartEndsTheRunningPhoneSessionAndAStaleScreenSaveDoesNotReopenIt() async throws {
        let worker = LiveSessionFileWorker(root: root)
        let phone = LiveSession(id: "live-p", title: "Budget meeting", startedAt: t0)
        try await worker.save(phone, generation: 1)
        _ = await worker.applyWatch(envelope(.sessionStart(watchSession(at: 300))), now: t0.addingTimeInterval(300))
        // The phone's screen still holds its running copy and saves it (a written Margin).
        var stale = phone
        stale.margins.append(stale.margin(id: "typed", text: "a note", markedAt: t0.addingTimeInterval(310)))
        try await worker.save(stale, generation: 2)
        let read7 = await worker.session(id: "live-p")
        let stored = try XCTUnwrap(read7)
        XCTAssertEqual(stored.endedAt, t0.addingTimeInterval(300), "still ended")
        XCTAssertEqual(stored.margins.map(\.id), ["typed"], "the screen's Margin is kept")
        let running = await worker.runningSession()
        XCTAssertEqual(running?.id, "live-w")
    }

    // MARK: Hello

    func testHelloAnswersWhatThePhoneAlreadyFiledAndLeavesTheRestToBeSentAgain() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0, durationMs: 2_000, sha256: sha("audio-m1")))
        _ = await worker.fileWatchInbox(now: t0) // its answer was lost
        let reply = await worker.applyWatch(envelope(.hello(holding: ["m1", "m2"])), now: t0.addingTimeInterval(60))
        XCTAssertEqual(reply.answers.map(\.receipt.captureId), ["m1"])
        XCTAssertEqual(reply.answers.first?.outcome, .alreadyFiled)
        XCTAssertEqual(reply.answers.first?.receipt.sha256, sha("audio-m1"), "the same bytes, so the Watch may let go")
        XCTAssertEqual(reply.answers.first?.filedWords, "Filed in a quick session")
        XCTAssertEqual(reply.phoneTime, t0.addingTimeInterval(60))
    }

    // MARK: Damage and deletion

    func testADamagedCopyIsAnsweredSoTheWatchSendsItAgain() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0, durationMs: 2_000, sha256: sha("the real bytes")), bytes: "cut short")
        let pass = await worker.fileWatchInbox(now: t0)
        let answer = try XCTUnwrap(pass.answers.first)
        XCTAssertFalse(answer.receipt.confirmsDelivery)
        XCTAssertFalse(answer.confirmsFiled)
        let read8 = await worker.allSessions().isEmpty
        XCTAssertTrue(read8, "nothing filed from damaged bytes")
        var good = WatchMarginTransfer(id: "m1", wallStart: t0, durationMs: 2_000, sha256: sha("the real bytes"))
        good.attempt = 2
        try deliver(worker, good, bytes: "the real bytes")
        let second = await worker.fileWatchInbox(now: t0)
        XCTAssertEqual(second.answers.first?.outcome, .filed)
    }

    func testAMarginDeletedOnTheWatchIsTakenOutAndALateCopyIsRefused() async throws {
        let worker = LiveSessionFileWorker(root: root)
        try deliver(worker, WatchMarginTransfer(id: "m1", wallStart: t0, durationMs: 2_000))
        _ = await worker.fileWatchInbox(now: t0)
        _ = await worker.applyWatch(envelope(.withdraw(id: "m1")), now: t0.addingTimeInterval(10))
        _ = await worker.fileWatchInbox(now: t0.addingTimeInterval(11))
        let read9 = await worker.allSessions().allSatisfy { $0.margins.isEmpty }
        XCTAssertTrue(read9)
        var late = WatchMarginTransfer(id: "m1", wallStart: t0, durationMs: 2_000)
        late.attempt = 2
        try deliver(worker, late)
        _ = await worker.fileWatchInbox(now: t0.addingTimeInterval(12))
        let read10 = await worker.allSessions().allSatisfy { $0.margins.isEmpty }
        XCTAssertTrue(read10, "never comes back")
        let hello = await worker.applyWatch(envelope(.hello(holding: ["m1"])), now: t0.addingTimeInterval(13))
        XCTAssertEqual(hello.answers.first?.outcome, .rejected)
    }
}
