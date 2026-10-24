import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #2487 slice 1a, inside the app: a Watch Margin goes through the receiver's own path (`receive(fileAt:metadata:)`,
/// what `session(_:didReceive:)` calls, then a filing pass) into a session the Library's Live row shows; and at launch
/// the running session is restored from today's `current.json` and its state is sent to the Watch. Real files in a
/// temporary Application Support; no WatchConnectivity pairing and no speech recognition.
@MainActor
final class LiveSessionFilingAppTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "live-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeReceiver(_ files: LiveSessionFileWorker, marks: [Date] = []) -> WatchMarginReceiver {
        let receiver = WatchMarginReceiver(files: files)
        receiver.transcribe = { _ in "testing no session" }
        var waiting = marks
        receiver.drainMarks = { defer { waiting = [] }; return waiting }
        return receiver
    }

    /// A file as WatchConnectivity hands it over, with the metadata today's Watch app sends.
    private func deliverWatchFile(_ receiver: WatchMarginReceiver, id: String, at start: Date) throws -> WatchMarginTransfer {
        let transfer = WatchMarginTransfer(id: id, wallStart: start, durationMs: 1_500)
        let file = root.appending(path: "wc-\(id).m4a")
        try Data("aac-\(id)".utf8).write(to: file)
        XCTAssertTrue(receiver.receive(fileAt: file, metadata: transfer.metadata))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "moved before iOS deletes it")
        return transfer
    }

    /// Owner check 1: with nothing running, a Watch Margin shows in the Library as a quick session.
    func testAWatchMarginWithNoSessionLandsInAQuickSessionTheLibraryShows() async throws {
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        let transfer = try deliverWatchFile(receiver, id: "w-quick", at: Date())

        await receiver.processInbox().value

        let rows = await files.summaries()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.isQuick, true)
        XCTAssertEqual(rows.first?.marginCount, 1)
        let board = LiveSessionBoard(files: files)
        await board.refreshNow()
        XCTAssertEqual(board.rows.map(\.id), rows.map(\.id))
        let quickId = try XCTUnwrap(rows.first?.id)
        let session = await files.session(id: quickId)
        XCTAssertEqual(session?.margins.map(\.id), [transfer.marginId])
        XCTAssertEqual(session?.margins.first?.text, "testing no session", "transcribed after filing")
        let recording = try XCTUnwrap(files.recordingURL(for: transfer.audioPath))
        XCTAssertEqual(try Data(contentsOf: recording), Data("aac-w-quick".utf8))
        // Stored, then filed, then answered.
        XCTAssertEqual(receiver.sentAnswers.map(\.outcome), [.filed])
        XCTAssertEqual(receiver.sentAnswers.first?.receipt.status, .stored)
        XCTAssertEqual(receiver.sentAnswers.first?.filedIn, "a quick session")
    }

    /// Owner checks 2 and 3: a meeting started before the app was closed is restored at launch, sent to the Watch, and
    /// takes the next Watch Margin.
    func testTheRunningSessionIsRestoredAtLaunchSentToTheWatchAndTakesWatchMargins() async throws {
        let started = Date().addingTimeInterval(-600)
        let meeting = LiveSession(id: "live-budget", kind: .meeting, title: "Budget meeting", startedAt: started, startPositionMs: 0)
        try LiveSessionStore.save(meeting, in: root) // today's current.json, as the build before this one wrote it

        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        await receiver.processInbox().value // what `activate()` runs at launch

        let context = try XCTUnwrap(receiver.lastPublishedContext)
        XCTAssertEqual(context[WatchLiveSessionContext.title] as? String, "Budget meeting")
        XCTAssertEqual(context[WatchLiveSessionContext.id] as? String, "live-budget")
        // current.json keeps milliseconds, so the restored start is the saved one to the millisecond.
        let sentStart = try XCTUnwrap(context[WatchLiveSessionContext.startedAt] as? Double)
        XCTAssertEqual(sentStart, started.timeIntervalSince1970, accuracy: 0.001)
        let board = LiveSessionBoard(files: files)
        await board.refreshNow()
        XCTAssertEqual(board.rows.map(\.id), ["live-budget"])
        XCTAssertEqual(board.rows.first?.isRunning, true)

        let transfer = try deliverWatchFile(receiver, id: "w-meeting", at: Date().addingTimeInterval(-30))
        await receiver.processInbox().value
        let restored = await files.session(id: "live-budget")
        XCTAssertEqual(restored?.margins.map(\.id), [transfer.marginId])
        XCTAssertEqual(receiver.sentAnswers.last?.filedIn, "Budget meeting")
        // The build before this one still finds it in current.json.
        XCTAssertEqual(LiveSessionStore.load(from: root)?.margins.map(\.id), [transfer.marginId])
    }

    /// Owner check 4: an hour after the meeting ended, a Watch Margin starts a new quick session, not the meeting.
    func testAWatchMarginAnHourAfterTheEndMakesAQuickSession() async throws {
        let ended = Date().addingTimeInterval(-3_600)
        try LiveSessionStore.save(LiveSession(id: "live-done", title: "Standup", startedAt: ended.addingTimeInterval(-900), endedAt: ended), in: root)
        let files = LiveSessionFileWorker(root: root)
        let receiver = makeReceiver(files)
        _ = try deliverWatchFile(receiver, id: "w-later", at: Date())
        await receiver.processInbox().value
        let done = await files.session(id: "live-done")
        XCTAssertEqual(done?.margins, [])
        let rows = await files.summaries()
        XCTAssertEqual(rows.filter(\.isQuick).map(\.marginCount), [1])
    }

    /// What an earlier build left waiting in the hidden inbox files on the first pass (slice 1a point 5).
    func testWhatTheHiddenInboxHeldFilesOnTheFirstPass() async throws {
        let files = LiveSessionFileWorker(root: root)
        let inbox = try XCTUnwrap(files.inboxDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let left = WatchMarginTransfer(id: "left-behind", wallStart: Date().addingTimeInterval(-86_400), durationMs: 900)
        try Data("old-aac".utf8).write(to: inbox.appending(path: "watch-left-behind.m4a"))
        try JSONEncoder().encode(left).write(to: inbox.appending(path: "watch-left-behind.json"))

        let receiver = makeReceiver(files)
        await receiver.processInbox().value

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
        let filed = await files.allSessions().flatMap(\.margins).map(\.id)
        XCTAssertEqual(filed, [left.marginId])
    }

    /// Slice 1a point 7: a Lock Screen Mark taken with no session is filed, not thrown away when the next session starts.
    func testALockScreenMarkWithNoSessionIsFiled() async throws {
        let files = LiveSessionFileWorker(root: root)
        let mark = Date().addingTimeInterval(-120)
        let receiver = makeReceiver(files, marks: [mark])
        await receiver.processInbox().value
        let margins = await files.allSessions().flatMap(\.margins)
        XCTAssertEqual(margins.map(\.isBlindMark), [true])
        XCTAssertEqual(margins.first?.markedAt, mark)
    }
}
