import Foundation
import XCTest
@testable import SessionKit

final class PlayQueueTests: XCTestCase {
    func testPlayNextPutsAnItemFirstAndMovesOneAlreadyQueued() {
        var queue = PlayQueue(itemIds: ["a", "b", "c"])
        queue.playNext("c")
        XCTAssertEqual(queue.itemIds, ["c", "a", "b"])
        queue.playNext("z")
        XCTAssertEqual(queue.itemIds, ["z", "c", "a", "b"])
    }

    func testAppendPutsAnItemLastAndKeepsAnItemAlreadyQueuedWhereItIs() {
        var queue = PlayQueue(itemIds: ["a", "b"])
        queue.append("c")
        queue.append("a")
        XCTAssertEqual(queue.itemIds, ["a", "b", "c"])
    }

    func testDuplicatesAreDroppedWhenAQueueIsBuilt() {
        XCTAssertEqual(PlayQueue(itemIds: ["a", "b", "a", "c", "b"]).itemIds, ["a", "b", "c"])
    }

    func testMoveRemoveAndClear() {
        var queue = PlayQueue(itemIds: ["a", "b", "c", "d"])
        queue.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(queue.itemIds, ["b", "c", "a", "d"])
        queue.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(queue.itemIds, ["d", "b", "c", "a"])
        queue.remove("c")
        XCTAssertEqual(queue.itemIds, ["d", "b", "a"])
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
    }

    func testAnItemDeletedAfterItWasQueuedNeverJamsTheQueue() {
        var queue = PlayQueue(itemIds: ["gone", "gone-too", "here", "later"])
        XCTAssertEqual(queue.popNext { $0.hasPrefix("here") || $0 == "later" }, "here")
        XCTAssertEqual(queue.itemIds, ["later"])
        XCTAssertEqual(queue.popNext { _ in false }, nil)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: when the queue moves on

    private func snapshot(session: String?, item: String?, phase: SessionPhase) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = session
        snapshot.itemId = item
        snapshot.phase = phase
        return snapshot
    }

    func testTheQueueAdvancesOnceWhenASessionReachesItsEnd() {
        let playing = snapshot(session: "s1", item: "a", phase: .itemPlayback)
        let finished = snapshot(session: "s1", item: "a", phase: .finished)
        XCTAssertTrue(PlayQueueAdvance.shouldAdvance(from: playing, to: finished))
        // The same finished snapshot arriving again (position ticks, a refresh) is not another finish.
        XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: finished, to: finished))
    }

    func testARestoredFinishedSessionOrAnotherSessionNeverAdvancesTheQueue() {
        let finished = snapshot(session: "s1", item: "a", phase: .finished)
        XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: SessionSnapshot(), to: finished))
        XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: snapshot(session: "s0", item: "a", phase: .itemPlayback), to: finished))
        XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: snapshot(session: "s1", item: "b", phase: .itemPlayback), to: finished))
        XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: snapshot(session: "s1", item: "a", phase: .itemPlayback),
                                                      to: snapshot(session: "s1", item: nil, phase: .finished)))
    }

    // MARK: the file

    func testTheQueueSurvivesReopeningTheFileAndAnEmptyQueueLeavesNoFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playqueue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayQueueStore(fileURL: directory.appendingPathComponent("PlayQueue/queue.json"))
        XCTAssertTrue(store.load().isEmpty)
        try store.save(PlayQueue(itemIds: ["a", "b"]))
        XCTAssertEqual(PlayQueueStore(fileURL: store.fileURL).load().itemIds, ["a", "b"])
        try store.save(PlayQueue())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testACorruptFileIsAnEmptyQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playqueue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("queue.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(PlayQueueStore(fileURL: file).load().isEmpty)
    }
}
