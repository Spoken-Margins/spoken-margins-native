import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #2487 slice 1b, inside the app: the phone's handling of the Watch's messages, through the receiver's own path
/// (`handle(_:)`, what both WatchConnectivity lanes call, and `receive(fileAt:metadata:)` for a file). Real files in a
/// temporary Application Support; no WatchConnectivity pairing and no speech recognition, which the simulator can't
/// do. What only paired devices show is the owner's check.
@MainActor
final class WatchContractAppTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "watch-contract-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeReceiver(_ files: LiveSessionFileWorker) -> WatchMarginReceiver {
        let receiver = WatchMarginReceiver(files: files)
        receiver.transcribe = { _ in "johnny was talking about the budget" }
        receiver.drainMarks = { [] }
        return receiver
    }

    private var seq = 0

    private func envelope(_ message: WatchMessage, sentAt: Date = Date(), clock: WatchClockStamp? = nil) -> WatchEnvelope {
        seq += 1
        return WatchEnvelope(seq: seq, sentAt: sentAt, clock: clock, message: message)
    }

    /// The dictionary as it crosses WatchConnectivity, read back as the phone's delegate reads it.
    private func overTheWire(_ envelope: WatchEnvelope) throws -> WatchEnvelope {
        try XCTUnwrap(WatchEnvelope(dictionary: envelope.dictionary))
    }

    private func deliver(_ receiver: WatchMarginReceiver, _ transfer: WatchMarginTransfer, bytes: String) throws {
        let file = root.appending(path: "wc-\(transfer.id)-\(transfer.attempt).m4a")
        try Data(bytes.utf8).write(to: file)
        XCTAssertTrue(receiver.receive(fileAt: file, metadata: transfer.metadata))
    }

    private func sha(_ text: String) throws -> String {
        let url = root.appending(path: "sha-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return try WatchMarginFolderStore<WatchMarginInbox.Entry>.digest(of: url).sha256
    }

    /// Owner check 3 and 4: Start session, Meeting on the Watch makes a running session on the phone, and a Margin
    /// recorded in it, with the Watch's clock two minutes ahead, is filed there and answered "Filed in Meeting, about
    /// 1:10".
    func testAWatchStartedMeetingRunsOnThePhoneAndItsMarginIsFiledThere() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        let clock = WatchClockStamp(offset: 120, measuredAt: Date())
        let watchStart = Date().addingTimeInterval(-200 + 120) // the phone's -200 s on a Watch two minutes ahead
        let meeting = WatchSessionInfo(id: "live-watch-meeting", kind: .meeting, title: "Meeting", owner: .watch, startedAt: watchStart)

        let reply = await receiver.handle(try overTheWire(envelope(.sessionStart(meeting), clock: clock))).value

        XCTAssertEqual(reply.board.running?.id, "live-watch-meeting")
        XCTAssertEqual(reply.board.running?.owner, .watch)
        let context = try XCTUnwrap(receiver.lastPublishedContext)
        XCTAssertEqual(WatchBoard(context: context)?.running?.id, "live-watch-meeting", "the state board the Watch reads")
        XCTAssertEqual(context[WatchLiveSessionContext.title] as? String, "Meeting")
        let running = await files.runningSession()
        XCTAssertEqual(running?.id, "live-watch-meeting")
        let liveRow = LiveSessionBoard(files: files)
        await liveRow.refreshNow()
        XCTAssertEqual(liveRow.rows.first?.isRunning, true, "the Library's Live row shows it running")

        let margin = WatchMarginTransfer(
            id: "w-budget", wallStart: watchStart.addingTimeInterval(70), durationMs: 2_400,
            sessionId: "live-watch-meeting", clock: clock, sha256: try sha("aac-budget")
        )
        try deliver(receiver, margin, bytes: "aac-budget")
        await receiver.processInbox().value

        let filed = try XCTUnwrap(receiver.sentAnswers.last)
        XCTAssertEqual(filed.outcome, .filed)
        XCTAssertEqual(filed.filedWords, "Filed in Meeting, about 1:10")
        let session = await files.session(id: "live-watch-meeting")
        let stored = try XCTUnwrap(session?.margins.first)
        XCTAssertEqual(stored.id, margin.marginId)
        XCTAssertEqual(stored.deviceMarkedAt, margin.wallStart, "the raw Watch time is kept")
        XCTAssertEqual(stored.markedAt.timeIntervalSince(margin.wallStart), -120, accuracy: 0.001, "corrected by the offset")
        XCTAssertEqual(stored.text, "johnny was talking about the budget")
    }

    /// The fast lane: a Margin's details after its file landed are answered "already filed", so the Watch shows Filed
    /// at once; before the file lands they get no answer, so the Watch keeps it.
    func testTheFastLaneAnswersOnlyAMarginThePhoneHasFiled() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        let margin = WatchMarginTransfer(id: "w-fast", wallStart: Date(), durationMs: 1_000, sha256: try sha("aac-fast"))

        var reply = await receiver.handle(try overTheWire(envelope(.marginDetails(margin)))).value
        XCTAssertTrue(reply.answers.isEmpty, "no file yet: no answer, and the Watch keeps its copy")

        try deliver(receiver, margin, bytes: "aac-fast")
        reply = await receiver.handle(try overTheWire(envelope(.marginDetails(margin)))).value
        XCTAssertEqual(reply.answers.first?.outcome, .alreadyFiled)
        XCTAssertEqual(reply.answers.first?.receipt.sha256, try sha("aac-fast"))
        XCTAssertEqual(reply.answers.first?.filedWords, "Filed in a quick session")
    }

    /// Hello after a lost answer: the reply answers what the phone filed; the rest gets nothing and is sent again.
    func testHelloClearsAStuckWaitingList() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        try deliver(receiver, WatchMarginTransfer(id: "w-lost", wallStart: Date(), durationMs: 1_000), bytes: "aac-lost")
        await receiver.processInbox().value

        let reply = await receiver.handle(try overTheWire(envelope(.hello(holding: ["w-lost", "w-unknown"])))).value

        XCTAssertEqual(reply.answers.map(\.receipt.captureId), ["w-lost"])
        XCTAssertEqual(reply.answers.first?.confirmsFiled, true)
        var ledger = WatchMarginLedger()
        ledger.record(WatchMarginTransfer(id: "w-lost", wallStart: Date(), durationMs: 1_000), fileName: "w-lost.m4a", now: Date())
        XCTAssertEqual(ledger.apply(try XCTUnwrap(reply.answers.first), now: Date()), .filed(fileName: "w-lost.m4a"))
    }

    /// Owner check 5: End on the Watch ends the phone's session, Resume reopens it, End again ends it; a session screen
    /// open on the phone follows, and its own save never reopens it.
    func testEndResumeEndFromTheWatchAndTheOpenScreenFollows() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        let start = Date().addingTimeInterval(-300)
        try await files.save(LiveSession(id: "live-phone", kind: .meeting, title: "Budget meeting", startedAt: start), generation: 1)
        let screen = LiveSessionController(sessionId: "live-phone", files: files)
        screen.load()
        try await waitUntil { screen.session?.id == "live-phone" }

        var reply = await receiver.handle(try overTheWire(envelope(.sessionEnd(id: "live-phone", endedAt: Date())))).value
        XCTAssertNil(reply.board.running)
        XCTAssertEqual(reply.board.recentlyEnded?.id, "live-phone", "the Watch offers Resume")
        try await waitUntil { screen.hasEnded }

        reply = await receiver.handle(try overTheWire(envelope(.sessionResume(id: "live-phone")))).value
        XCTAssertEqual(reply.board.running?.id, "live-phone")
        try await waitUntil { screen.isRunning }

        screen.addMargin(text: "typed on the phone", whereNote: nil, adjustmentMs: 0)
        reply = await receiver.handle(try overTheWire(envelope(.sessionEnd(id: "live-phone", endedAt: Date())))).value
        XCTAssertNil(reply.board.running)
        try await waitUntil { screen.hasEnded }
        let read = await files.session(id: "live-phone")
        let stored = try XCTUnwrap(read)
        XCTAssertNotNil(stored.endedAt)
        XCTAssertEqual(stored.margins.map(\.text), ["typed on the phone"])
        screen.stopPolling()
    }

    /// The phone starting a session ends the one the Watch started, and the board says so in words.
    func testThePhoneEndingAWatchSessionIsToldToTheWatch() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        let lecture = WatchSessionInfo(id: "live-lecture", kind: .other, title: "Lecture", owner: .watch, startedAt: Date().addingTimeInterval(-600))
        _ = await receiver.handle(try overTheWire(envelope(.sessionStart(lecture)))).value
        try await files.save(LiveSession(id: "live-phone", kind: .meeting, title: "Meeting", startedAt: Date()), generation: 1)

        let reply = await receiver.handle(try overTheWire(envelope(.hello(holding: [])))).value

        XCTAssertEqual(reply.board.running?.id, "live-phone")
        let note = try XCTUnwrap(reply.board.endNotes["live-lecture"])
        XCTAssertTrue(note.hasPrefix("Lecture ended at "), note)
        XCTAssertTrue(note.hasSuffix("when you started Meeting on iPhone"), note)
        var model = WatchSessionModel()
        _ = model.start(kind: .other, id: "live-lecture", now: lecture.startedAt)
        model.apply(reply.board, receivedAt: Date())
        XCTAssertEqual(model.endNote, note, "the Watch shows the phone's words")
    }

    /// Delete on the Watch takes a Margin the phone filed out again, and a late copy is refused.
    func testDeleteOnTheWatchWithdrawsTheMargin() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        let margin = WatchMarginTransfer(id: "w-oops", wallStart: Date(), durationMs: 1_000)
        try deliver(receiver, margin, bytes: "aac-oops")
        await receiver.processInbox().value
        _ = await receiver.handle(try overTheWire(envelope(.withdraw(id: "w-oops")))).value
        let left = await files.allSessions().flatMap(\.margins)
        XCTAssertTrue(left.isEmpty)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
