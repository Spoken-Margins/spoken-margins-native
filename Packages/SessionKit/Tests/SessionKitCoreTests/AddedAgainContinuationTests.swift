import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4183, after #4178: an article the listener heard and then added again was listed first and counted as unfinished,
/// but its Library row still read every session. For an essay heard to the end the row said "100%" and "Replay", the
/// "Unplayed" filter hid it, and Continue on a session left at 99% resumed near its end and finished it again after a
/// few seconds. These tests run the real import on a real SQLite store and read the row, the filters, `PlayRule` and
/// the item screen's state the way the app does, so the four agree.
final class AddedAgainContinuationTests: XCTestCase {
    private var root: URL!
    private var path: String!
    private var store: SQLiteSessionStore!
    private var engine: SessionEngine!
    private let rowContext = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true)
    private let tenDaysAgo = Date(timeIntervalSinceNow: -86_400 * 10)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: path)
        engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test",
            capabilities: ["sync": ["canonical_persistence", "browser_session_handoff"]]), repository: store)
    }

    override func tearDownWithError() throws {
        engine = nil
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private let essay = BrowserTextHandoff(
        captureMode: .readablePage,
        source: BrowserTextSource(url: "https://institute.example/essays/the-economics-of-intelligence/",
                                  title: "AGI Economics: Coordination vs. Competence"),
        text: "# The Economics of Intelligence\n\nSmarter AI will increase productivity.\n\nThe rest of the essay.",
        contentFormat: .markdown)

    /// The essay as it stood ten days ago, with one session the listener left at `percent`: finished when asked.
    @discardableResult
    private func essayHeard(percent: Int, finished: Bool = false) throws -> Item {
        var item = try engine.importBrowserTextInBackground(essay)
        item.createdAt = tenDaysAgo
        try store.saveItem(item)
        try store.saveSession(Session(
            id: "heard", itemId: item.id, createdAt: tenDaysAgo, updatedAt: tenDaysAgo, completedAt: finished ? tenDaysAgo : nil,
            status: finished ? "finished" : "in_progress", phase: finished ? .finished : .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: percent), completionPercent: percent, playbackRate: 1))
        return item
    }

    private func rows(in store: SQLiteSessionStore? = nil, query: LibraryQuery = LibraryQuery()) throws -> [LibraryItemRow] {
        let all = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store ?? self.store), context: rowContext)
        return LibraryQueryEngine.visibleLibraryItems(all, query: query)
    }

    private func query(listening: LibraryListeningStateFilter) -> LibraryQuery {
        LibraryQuery(listeningState: listening)
    }

    /// What `startItem` does: the item's stored sessions, and the re-add stamp the Library row carries (the model holds the
    /// row, so no extra read runs on the main thread).
    private func startAction(_ itemId: String, in store: SQLiteSessionStore? = nil) throws -> PlayRule.StartAction {
        let store: SQLiteSessionStore = store ?? self.store
        let row = try rows(in: store, query: query(listening: .all)).first { $0.id == itemId }
        return PlayRule.startAction(sessions: try store.loadSessions(itemId: itemId), addedAgainAt: row?.addedAgainAt)
    }

    // MARK: The table

    func testAnEssayHeardToTheEndThenSharedAgainReadsAsAFreshAddEverywhere() throws {
        let heard = try essayHeard(percent: 100, finished: true)
        _ = try engine.importBrowserTextInBackground(essay)

        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.id, heard.id)
        XCTAssertEqual(row.addedAgainAt, try store.loadItem(id: heard.id).addedAgainAt, "the row carries the stamp Play filters with")
        XCTAssertNil(row.continuationProgressPercent, "no \"100%\" on a fresh add")
        XCTAssertFalse(row.hasContinuationSession, "so the play button says Start, not Replay")
        XCTAssertTrue(try rows(query: query(listening: .unplayed)).contains { $0.id == heard.id }, "listed under Unplayed")
        XCTAssertFalse(try rows(query: query(listening: .inProgress)).contains { $0.id == heard.id }, "not under In progress")
        XCTAssertEqual(try startAction(heard.id), .startNew, "Play starts a new session at the beginning")
        XCTAssertEqual(try store.loadSessions(itemId: heard.id).map(\.id), ["heard"], "the old listening is kept as history")
    }

    func testASessionLeftAtNinetyNineIsNotResumedNearItsEndAfterAReAdd() throws {
        let heard = try essayHeard(percent: 99)
        XCTAssertEqual(try startAction(heard.id), .resume(try XCTUnwrap(try store.loadSession(id: "heard"))),
                       "control: before the re-add, Continue resumes it near its end")
        _ = try engine.importBrowserTextInBackground(essay)

        let row = try XCTUnwrap(try rows().first)
        XCTAssertNil(row.continuationProgressPercent)
        XCTAssertFalse(row.hasContinuationSession)
        XCTAssertEqual(try startAction(heard.id), .startNew, "a few seconds of play would have finished it again")
    }

    func testASessionPartWayKeepsItsPlaceAfterAReAdd() throws {
        let heard = try essayHeard(percent: 40)
        _ = try engine.importBrowserTextInBackground(essay)

        let row = try XCTUnwrap(try rows().first)
        XCTAssertEqual(row.continuationProgressPercent, 40)
        XCTAssertTrue(row.hasContinuationSession)
        XCTAssertTrue(try rows(query: query(listening: .inProgress)).contains { $0.id == heard.id })
        XCTAssertFalse(try rows(query: query(listening: .unplayed)).contains { $0.id == heard.id })
        XCTAssertEqual(try startAction(heard.id), .resume(try XCTUnwrap(try store.loadSession(id: "heard"))))
    }

    func testAnEssayNeverSharedAgainStillReadsAsFinished() throws {
        let heard = try essayHeard(percent: 100, finished: true)
        let row = try XCTUnwrap(try rows(query: query(listening: .all)).first { $0.id == heard.id })
        XCTAssertEqual(row.continuationProgressPercent, 100, "unchanged for an item never added again")
        XCTAssertTrue(row.isCompleted)
    }

    func testAnOlderFinishedSessionAndANewerPartWayOneLeaveThePartWayOneToDecide() throws {
        let heard = try essayHeard(percent: 100, finished: true)
        _ = try engine.importBrowserTextInBackground(essay)
        let later = Date(timeIntervalSinceNow: 60)
        try store.saveSession(Session(
            id: "again", itemId: heard.id, createdAt: later, updatedAt: later, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: heard.id, position: Position(charOffset: 30),
            completionPercent: 25, playbackRate: 1))

        XCTAssertEqual(try rows().first?.continuationProgressPercent, 25)
        XCTAssertEqual(try startAction(heard.id), .resume(try XCTUnwrap(try store.loadSession(id: "again"))))
    }

    // MARK: Starting states

    /// `relaunch`: re-add, quit, reopen. The row and Continue read the same from a new store over the same file.
    func testTheRowAndContinueStillReadFreshAfterARelaunch() throws {
        let heard = try essayHeard(percent: 100, finished: true)
        _ = try engine.importBrowserTextInBackground(essay)
        engine = nil
        store = nil

        let reopened = try SQLiteSessionStore(path: path)
        let row = try XCTUnwrap(try rows(in: reopened).first)
        XCTAssertEqual(row.id, heard.id)
        XCTAssertNil(row.continuationProgressPercent)
        XCTAssertEqual(try startAction(heard.id, in: reopened), .startNew)
    }

    /// `burst`: the same article shared twice in a second is one item, and the rule gives the same answer for either stamp.
    func testTheSameArticleSharedTwiceInASecondGivesOneItemAndTheSameAnswer() throws {
        let heard = try essayHeard(percent: 100, finished: true)
        _ = try engine.importBrowserTextInBackground(essay)
        let first = try XCTUnwrap(try store.loadItem(id: heard.id).addedAgainAt)
        let again = try engine.importBrowserTextInBackground(essay)

        XCTAssertEqual(again.id, heard.id)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(try store.loadItem(id: heard.id).addedAgainAt), first)
        XCTAssertEqual(try rows().filter { $0.id == heard.id }.count, 1)
        XCTAssertNil(try rows().first { $0.id == heard.id }?.continuationProgressPercent)
        XCTAssertEqual(try startAction(heard.id), .startNew)
    }

    /// The item screen reads the same rule: its Play choice and button follow `continuationSessions`, and "Listening
    /// sessions" still lists the earlier pass.
    func testTheItemScreenReadsTheSameRuleAndKeepsTheHistory() throws {
        let heard = try essayHeard(percent: 100, finished: true)
        _ = try engine.importBrowserTextInBackground(essay)

        let detail = try ItemDetailLoader.load(id: heard.id, store: store, snapshotItemId: nil, snapshotSessionId: nil,
                                               placementPasses: SharedMarginPlacementPasses())
        XCTAssertNotNil(detail.addedAgainAt)
        XCTAssertEqual(detail.sessions.map(\.id), ["heard"], "the history keeps every pass")
        XCTAssertEqual(detail.continuationSessions.map(\.id), [], "nothing to continue or replay")
        XCTAssertNil(SessionContinuation.preferredContinuationSession(in: detail.continuationSessions))
    }
}
