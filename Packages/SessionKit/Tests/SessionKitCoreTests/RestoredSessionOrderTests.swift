import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// Relaunch restores `store.loadSessions().first { isResumable && its item is in the Library }`
/// (`Gate1AppModel.bootstrap`). The app test had one session, so a store that returned the oldest first, or a
/// rule that restored a finished session, passed it (APM-07). These tests pin the two pieces that line depends on,
/// on a real SQLite file: the store's newest-first order, and which sessions count as resumable.
/// The `availableItemIDs` filter and the `first` call stay in the app lane's test.
final class RestoredSessionOrderTests: XCTestCase {
    private var directory: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "restored-session-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(
        _ id: String, item: String = "item-a", status: String = "in_progress", phase: SessionPhase = .itemPlayback,
        updated: TimeInterval?, created: TimeInterval? = nil
    ) -> Session {
        Session(
            id: id, itemId: item,
            createdAt: created.map(Date.init(timeIntervalSince1970:)),
            updatedAt: updated.map(Date.init(timeIntervalSince1970:)),
            status: status, phase: phase, currentTargetType: .itemTextTTS, currentTargetId: item,
            position: Position(), completionPercent: status == "finished" ? 100 : 10, playbackRate: 1
        )
    }

    /// The model's selection, with the Library filter left out.
    private func restored() throws -> Session? {
        try store.loadSessions().first { SessionContinuation.isResumableSession($0) }
    }

    func testTheNewestInProgressSessionIsFirstWhateverOrderTheyWereSaved() throws {
        let sessions = [
            session("s-old", updated: 1_000),
            session("s-newer", item: "item-b", updated: 3_000),
            session("s-middle", updated: 2_000),
        ]
        for ordering in [sessions, sessions.reversed(), [sessions[1], sessions[0], sessions[2]]] {
            for saved in ordering { try store.saveSession(saved) }
            XCTAssertEqual(try store.loadSessions().map(\.id), ["s-newer", "s-middle", "s-old"])
            XCTAssertEqual(try restored()?.id, "s-newer", "relaunch restores the newest, not the oldest")
        }
    }

    func testAFinishedOrAbandonedSessionIsNeverRestoredEvenWhenNewest() throws {
        try store.saveSession(session("s-in-progress", updated: 1_000))
        try store.saveSession(session("s-finished", status: "finished", phase: .finished, updated: 3_000))
        try store.saveSession(session("s-abandoned", phase: .abandoned, updated: 4_000))

        XCTAssertEqual(try store.loadSessions().first?.id, "s-abandoned", "the newest session overall is not the one restored")
        XCTAssertEqual(try restored()?.id, "s-in-progress")
    }

    func testOnlyNonResumableSessionsMeansNothingIsRestored() throws {
        try store.saveSession(session("s-finished", status: "finished", phase: .finished, updated: 3_000))
        try store.saveSession(session("s-abandoned", phase: .abandoned, updated: 4_000))
        XCTAssertNil(try restored())
    }

    func testAnUpdatedSessionMovesAheadOfANewerlyCreatedOne() throws {
        try store.saveSession(session("s-created-later", updated: 2_000, created: 2_000))
        try store.saveSession(session("s-resumed-since", updated: 5_000, created: 1_000))
        XCTAssertEqual(try restored()?.id, "s-resumed-since", "last activity decides, not the creation date")
    }

    func testSessionsWithTheSameTimeBreakTheTieByIDLargestFirst() throws {
        try store.saveSession(session("s-1", updated: 2_000))
        try store.saveSession(session("s-3", updated: 2_000))
        try store.saveSession(session("s-2", updated: 2_000))
        XCTAssertEqual(try store.loadSessions().map(\.id), ["s-3", "s-2", "s-1"])
    }

    func testASessionFromAnOlderBuildWithNoTimestampsSortsLast() throws {
        try store.saveSession(session("s-no-dates", updated: nil))
        try store.saveSession(session("s-dated", updated: 1_000))
        XCTAssertEqual(try store.loadSessions().map(\.id), ["s-dated", "s-no-dates"])
        XCTAssertEqual(try restored()?.id, "s-dated")
    }
}
