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
        // The file's metadata carries the time as seconds since 1970, so a `Date()` comes back a few ulps off.
        let deviceMarkedAt = try XCTUnwrap(stored.deviceMarkedAt, "the raw Watch time is kept")
        XCTAssertEqual(deviceMarkedAt.timeIntervalSince(margin.wallStart), 0, accuracy: 0.001, "the raw Watch time is kept")
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

    /// #3494: a fresh fast-lane transport command reaches the player at once, a stale one or a sure-lane copy never does, and the reply board names the
    /// item the player has loaded.
    func testAFreshTransportRunsAStaleOneDoesNotAndTheReplyBoardNamesTheItem() async throws {
        let receiver = makeReceiver(LiveSessionFileWorker(root: root))
        var ran: [WatchTransport] = []
        receiver.runTransport = { ran.append($0) }
        let playing = WatchNowPlaying(itemId: "ep", title: "Episode", isPlaying: true, positionMs: 5_000, positionAt: Date())
        receiver.nowPlayingChanged(playing)

        let fresh = try await receiver.handle(try overTheWire(envelope(.transport(.pause), sentAt: Date()))).value
        XCTAssertEqual(ran, [.pause])
        XCTAssertEqual(fresh.board.nowPlaying, playing)

        let stale = try await receiver.handle(try overTheWire(envelope(.transport(.skipForward), sentAt: Date().addingTimeInterval(-60)))).value
        XCTAssertEqual(ran, [.pause], "a skip that arrives a minute late is dropped")
        XCTAssertEqual(stale.board.nowPlaying, playing)

        _ = await receiver.handle(try overTheWire(envelope(.transport(.skipBack), sentAt: Date())), fastLane: false).value
        XCTAssertEqual(ran, [.pause], "the sure lane never runs a transport command")

        receiver.nowPlayingChanged(nil)
        let none = await receiver.handle(try overTheWire(envelope(.hello(holding: [])))).value
        XCTAssertNil(none.board.nowPlaying, "nothing loaded: the Watch goes back to its single Record")
    }

    /// #3494: a command the player refuses changes nothing that would send a board, yet the Watch has already flipped its
    /// button. The board still goes out once more after the command, so the Watch ends up with the player's real state.
    func testTheBoardGoesOutOnceMoreAfterATransportCommandEvenWhenNothingChanged() async throws {
        let receiver = makeReceiver(LiveSessionFileWorker(root: root))
        // #4058: the reply's own board and this settle board come from different tasks and can publish in either order.
        // The test used to note the reply's board and wait for a newer one, so a reply slower than the settle (a loaded
        // runner) left the settle board already published and nothing newer ever came. It now waits for a board computed
        // at least one settle after the command, which only the settle board (or a reply that slow) can be.
        let settle = Duration.milliseconds(300)
        receiver.transportSettle = settle
        receiver.runTransport = { _ in } // the player refuses it
        let paused = WatchNowPlaying(itemId: "ep", title: "Episode", isPlaying: false, positionMs: 5_000, positionAt: Date())
        receiver.nowPlayingChanged(paused)

        let commandAt = Date()
        let settledAfter = commandAt.addingTimeInterval(0.3)
        _ = try await receiver.handle(try overTheWire(envelope(.transport(.play), sentAt: commandAt))).value

        for _ in 0..<100 where (receiver.lastBoard?.phoneTime ?? .distantPast) < settledAfter {
            try await Task.sleep(for: .milliseconds(50))
        }
        let settled = try XCTUnwrap(receiver.lastBoard)
        XCTAssertGreaterThanOrEqual(settled.phoneTime, settledAfter, "a board goes out after the command, with nothing changed")
        XCTAssertEqual(settled.nowPlaying?.isPlaying, false, "and it says the item is still paused")
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
