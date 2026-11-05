import Foundation
@testable import SessionKit
import SessionKitPersistence
import XCTest

/// A streamed reply's cursor is saved off the main thread and is never lost (#2509).
final class StreamedTurnCursorWriterTests: XCTestCase {
    private let turnId = "turn-stream"
    private let reply = "First sentence here. Second sentence follows. Third one ends it."
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StreamedTurnCursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Fails on the code before #2509: each report decoded the session's turns and wrote the Session row on the
    /// calling thread, which in the app is the main thread, twice a second while a reply is heard.
    func testCursorReportsNeitherDecodeTurnsNorWriteOnTheCallingThread() throws {
        XCTAssertTrue(Thread.isMainThread)
        let repo = ThreadRecordingRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo)
        _ = try engine.aiStreamDelta(turnId: turnId, content: reply)
        _ = try engine.activateStreamingTurn(turnId: turnId)
        repo.resetCounts()

        for offset in stride(from: 0, through: 40, by: 2) {
            _ = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: offset)
        }

        XCTAssertEqual(repo.mainThreadSessionSaves, 0, "a cursor report wrote the Session row on the main thread")
        XCTAssertEqual(repo.mainThreadTurnLoads, 0, "a cursor report decoded the turns on the main thread")
        XCTAssertEqual(engine.currentSession?.position.charOffset, 40)
        engine.flushPendingSessionWrites()
        XCTAssertEqual(try repo.loadSession(id: session.id)?.position.charOffset, 40)
    }

    /// The lifecycle sync the app runs as it leaves the foreground leaves the newest place on disk, so a kill while
    /// suspended loses nothing: a second connection to the same file, as after a relaunch, reads it.
    func testTheNewestPlaceIsOnDiskAfterTheLifecycleSync() throws {
        let path = root.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.seed(item: item)
        try store.saveSession(session)
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.aiStreamDelta(turnId: turnId, content: reply)
        _ = try engine.activateStreamingTurn(turnId: turnId)

        for offset in 0..<45 {
            _ = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: offset)
        }
        _ = try engine.syncPlaybackProgress() // what handleAppBecameInactiveOrBackground runs

        let relaunched = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try relaunched.loadSession(id: session.id)?.position.charOffset, 44)
        XCTAssertEqual(try relaunched.loadSession(id: session.id)?.currentTargetId, turnId)
    }

    /// A Session write the engine makes itself (here, the reply ending) lands after the queued cursor, never under it.
    func testTheEnginesOwnWriteIsNotOverwrittenByAQueuedCursor() throws {
        let path = root.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.seed(item: item)
        try store.saveSession(session)
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.aiStreamDelta(turnId: turnId, content: reply)
        _ = try engine.activateStreamingTurn(turnId: turnId)

        for offset in 0..<30 {
            _ = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: offset)
        }
        _ = try engine.finishStreamingTurnPlayback(turnId: turnId)

        let relaunched = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try relaunched.loadSession(id: session.id)?.position.charOffset, reply.count)
    }

    /// Reports that arrive while a write is waiting become one write of the newest place.
    func testABurstOfReportsBecomesOneWriteOfTheNewest() throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("burst.sqlite").path)
        try store.seed(item: item)
        try store.saveSession(session)
        let queue = DispatchQueue(label: "StreamedTurnCursorWriterTests.burst")
        let writer = StreamedTurnCursorWriter(repository: store, queue: queue)

        queue.suspend()
        for offset in 0..<50 {
            var moved = session
            moved.position.charOffset = offset
            writer.submit(moved, turnId: turnId)
        }
        queue.resume()
        writer.flush()

        XCTAssertEqual(writer.writeCount, 1)
        XCTAssertEqual(try store.loadSession(id: session.id)?.position.charOffset, 49)
        XCTAssertNil(writer.takeFailure())
    }

    /// After each write the writer reads the turn again, so a reply that grew or finished clamps to its new text.
    func testTheShapeIsReadAgainAfterEachWrite() throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("shape.sqlite").path)
        try store.seed(item: item)
        try store.saveSession(session)
        var turn = ConversationTurn(
            id: turnId, sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "streaming",
            summary: nil, text: "Short.", rawText: nil, chapters: nil, sourceInterjectionIds: []
        )
        try store.saveTurn(turn)
        let writer = StreamedTurnCursorWriter(repository: store)
        writer.seed(turnId: turnId, turn: turn)

        turn.status = "complete"
        turn.text = reply
        turn.chapters = [Chapter(id: "c1", title: "One", startChar: 0, endChar: 20, percent: 50), Chapter(id: "c2", title: "Two", startChar: 21, endChar: reply.count, percent: 100)]
        try store.saveTurn(turn)
        writer.submit(session, turnId: turnId)
        writer.flush()

        let shape = try XCTUnwrap(writer.shape(for: turnId))
        XCTAssertEqual(shape.textLength, reply.count)
        XCTAssertTrue(shape.isComplete)
        XCTAssertEqual(shape.position(charOffset: 30).chapterId, "c2")
        XCTAssertNil(writer.shape(for: "another-turn"))
    }

    private var chapterReply: String {
        "<sm_summary>Two parts.</sm_summary><sm_response>Hello world. Second point.</sm_response>"
            + "<sm_chapters_json>{\"schemaVersion\":\"assistant-response-map.v1\",\"chapters\":[{\"id\":\"ch-1\",\"title\":\"Opening\",\"anchor\":\"Hello world.\"}]}</sm_chapters_json>"
    }

    private func pausedStreamingEngine(in store: SQLiteSessionStore) throws -> SessionEngine {
        try store.seed(item: item)
        try store.saveSession(session)
        let engine = SessionEngine(profile: profile, repository: store)
        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.aiStreamDelta(turnId: turnId, content: chapterReply)
        _ = try engine.activateStreamingTurn(turnId: turnId)
        _ = try engine.streamingTurnPlaybackStarted(turnId: turnId, charOffset: 0)
        _ = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: 2)
        _ = try engine.pause() // pause while the reply is still generating: its last cursor report re-reads the turn
        engine.flushPendingSessionWrites()
        return engine
    }

    /// Fails without the shared save helper (#2509 audit): the generation finishing saved the turn complete with its
    /// chapters, but the cursor writer's copy still said "streaming, no chapters", so the published progress showed
    /// the turn's title, not the chapter's.
    func testAFinishedReplyShowsItsChapterTitleAfterAPauseDuringGeneration() throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("finish.sqlite").path)
        let engine = try pausedStreamingEngine(in: store)

        let published = try engine.aiJobCompleted(turnId: turnId)

        XCTAssertEqual(published.chapterTitle, "Opening")
    }

    /// The same for chapters that arrive on their own (the chapter-title job), not with the reply.
    func testChaptersThatArriveAfterAPauseDuringGenerationAreShown() throws {
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("chapters.sqlite").path)
        let engine = try pausedStreamingEngine(in: store)

        _ = try engine.aiChaptersCompleted(
            turnId: turnId,
            chapters: [Chapter(id: "late", title: "Late Title", startChar: 0, endChar: 12, percent: 50)]
        )
        let published = try engine.syncPlaybackProgress()

        XCTAssertEqual(published.chapterTitle, "Late Title")
    }

    /// Neighbouring offsets: negative, inside, at and past the end, for a complete and a still-growing turn.
    func testWhereAReportedOffsetLands() {
        let chapters = [Chapter(id: "a", title: "A", startChar: 0, endChar: 9, percent: 50), Chapter(id: "b", title: "B", startChar: 10, endChar: 20, percent: 50)]
        let complete = StreamedTurnCursorWriter.Shape(turn: ConversationTurn(
            id: "t", sessionId: "s", role: "assistant", turnType: "assistant_response", status: "complete",
            summary: nil, text: "  0123456789abcdefghij  ", rawText: nil, chapters: chapters, sourceInterjectionIds: []
        ))
        XCTAssertEqual(complete.textLength, 20)
        let rows: [(Int, Int, String?)] = [(-5, 0, "a"), (0, 0, "a"), (9, 9, "a"), (10, 10, "b"), (20, 20, "b"), (500, 20, "b")]
        for (reported, expected, chapter) in rows {
            XCTAssertEqual(complete.position(charOffset: reported).charOffset, expected, "complete, reported \(reported)")
            XCTAssertEqual(complete.position(charOffset: reported).chapterId, chapter, "complete, reported \(reported)")
        }

        let growing = StreamedTurnCursorWriter.Shape(turn: ConversationTurn(
            id: "t", sessionId: "s", role: "assistant", turnType: "assistant_response", status: "streaming",
            summary: nil, text: "Short.", rawText: nil, chapters: nil, sourceInterjectionIds: []
        ))
        XCTAssertEqual(growing.position(charOffset: -1).charOffset, 0)
        XCTAssertEqual(growing.position(charOffset: 40).charOffset, 40, "a growing reply may already be longer than the shape read")
        XCTAssertNil(growing.position(charOffset: 3).chapterId)
    }

    private var profile: RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"], "playback": ["assistant_turn_tts"]]
        )
    }

    private var item: Item {
        Item(id: "item-stream", title: "Stream", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
    }

    private var session: Session {
        Session(
            id: "session-stream", itemId: item.id, status: "in_progress", phase: .conversation,
            currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1
        )
    }
}

/// Counts the Session writes and turn reads that ran on the main thread.
private final class ThreadRecordingRepository: InMemorySessionRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var sessionSaves = 0
    private var turnLoads = 0

    var mainThreadSessionSaves: Int { lock.withLock { sessionSaves } }
    var mainThreadTurnLoads: Int { lock.withLock { turnLoads } }

    func resetCounts() {
        lock.withLock {
            sessionSaves = 0
            turnLoads = 0
        }
    }

    override func saveSession(_ session: Session) throws {
        if Thread.isMainThread { lock.withLock { sessionSaves += 1 } }
        try super.saveSession(session)
    }

    override func loadTurns(sessionId: String) throws -> [ConversationTurn] {
        if Thread.isMainThread { lock.withLock { turnLoads += 1 } }
        return try super.loadTurns(sessionId: sessionId)
    }
}
