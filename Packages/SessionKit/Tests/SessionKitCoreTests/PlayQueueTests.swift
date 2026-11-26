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

    // MARK: permanent delete (#4227)

    func testRemoveAllInTakesOutOnlyTheNamedItemsAndKeepsTheOrder() {
        var queue = PlayQueue(itemIds: ["a", "b", "c", "d", "e"])
        queue.removeAll(in: ["d", "b", "not-queued"])
        XCTAssertEqual(queue.itemIds, ["a", "c", "e"])
        queue.removeAll(in: [String]())
        XCTAssertEqual(queue.itemIds, ["a", "c", "e"])
        queue.removeAll(in: ["a", "c", "e"])
        XCTAssertTrue(queue.isEmpty)
    }

    /// The queue's file keeps an id until something rewrites it, so a deleted item that is imported again under the same
    /// id (a packet's id is deterministic) came back into the queue it had been deleted from.
    func testRemovingDeletedItemsRewritesTheQueueFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlayQueueStore(fileURL: directory.appendingPathComponent("play-queue.json"))
        try store.save(PlayQueue(itemIds: ["a", "gone", "b"]))
        var queue = store.load()
        queue.removeAll(in: ["gone"])
        try store.save(queue)
        XCTAssertEqual(PlayQueueStore(fileURL: store.fileURL).load().itemIds, ["a", "b"])
        // Removing the last queued item leaves no file, as the store always has.
        var last = store.load()
        last.removeAll(in: ["a", "b"])
        try store.save(last)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// A table of neighbouring cases for which queued ids count as orphans.
    func testOrphansAreIdsInNeitherTheLibraryNorTheAppsLists() {
        let queue = PlayQueue(itemIds: ["stored", "trashed", "just-imported", "gone", "Gone", "gone "])
        // `trashed` is a stored row (Recently Deleted keeps it); `just-imported` is on the app's lists but was added
        // after the stored ids were read.
        let orphans = PlayQueueOrphans.orphans(
            in: queue, storedIds: ["stored", "trashed"], knownNow: ["just-imported", "stored"])
        // Ids are compared exactly: a different case or a trailing space is a different item.
        XCTAssertEqual(orphans, ["gone", "Gone", "gone "])
        XCTAssertEqual(PlayQueueOrphans.orphans(in: PlayQueue(), storedIds: [], knownNow: []), [])
        // An empty answer from the store removes nothing it should keep: the app's lists still protect their items.
        XCTAssertEqual(
            PlayQueueOrphans.orphans(in: PlayQueue(itemIds: ["a", "b"]), storedIds: [], knownNow: ["a"]), ["b"])
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

    /// #5358: every end gets one decision, for the advance and for Diagnostics; an ordinary change gets none.
    func testEachEndGetsOneDecisionWithItsReason() {
        var playing = snapshot(session: "s1", item: "a", phase: .itemPlayback)
        playing.status = .playing
        playing.targetId = "a"
        var finished = playing
        finished.phase = .finished
        finished.status = .paused
        finished.currentPlaybackProgressPercent = 100
        XCTAssertEqual(PlayQueueAdvance.decision(from: playing, to: finished, sleepTimerActive: false, queueHasNext: true), .advance)
        XCTAssertEqual(PlayQueueAdvance.decision(from: playing, to: finished, sleepTimerActive: true, queueHasNext: true),
                       .skipped(.sleepTimer))
        XCTAssertEqual(PlayQueueAdvance.decision(from: playing, to: finished, sleepTimerActive: false, queueHasNext: false),
                       .skipped(.queueEmpty))
        XCTAssertNil(PlayQueueAdvance.decision(from: finished, to: finished, sleepTimerActive: false, queueHasNext: true))

        // Stopped at its end without the finish edge: what a skip to the end of an article used to do.
        var stoppedAtEnd = finished
        stoppedAtEnd.phase = .itemPlayback
        XCTAssertEqual(PlayQueueAdvance.decision(from: playing, to: stoppedAtEnd, sleepTimerActive: false, queueHasNext: true),
                       .skipped(.noFinishEdge))
        // A pause in the middle is no end.
        var pausedMidway = stoppedAtEnd
        pausedMidway.currentPlaybackProgressPercent = 40
        XCTAssertNil(PlayQueueAdvance.decision(from: playing, to: pausedMidway, sleepTimerActive: false, queueHasNext: true))
        // Nor is a change of session or of target (a Margin's playback ending, a new item starting).
        var otherTarget = stoppedAtEnd
        otherTarget.targetId = "turn-1"
        XCTAssertNil(PlayQueueAdvance.decision(from: playing, to: otherTarget, sleepTimerActive: false, queueHasNext: true))

        XCTAssertEqual(PlayQueueAdvance.Decision.advance.diagnosticFields, ["outcome": "advanced"])
        XCTAssertEqual(PlayQueueAdvance.Decision.skipped(.noFinishEdge).diagnosticFields,
                       ["outcome": "skipped", "reason": "no_finish_edge"])
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

    // MARK: three in a row (#1990 verification)

    /// Plays a queue the way the app does: each finish is a snapshot edge, the edge pops the next available item from the
    /// queue file, and the queue file is written back after each hop. The file is reopened between hops, so this also
    /// covers the app being closed and reopened mid-run.
    func testThreeQueuedItemsPlayInOrderAcrossReopeningTheFileAndSkipADeletedOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("playqueue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("play-queue.json")
        let library: Set<String> = ["a", "b", "d"] // "c" was queued, then deleted from the Library
        try PlayQueueStore(fileURL: fileURL).save(PlayQueue(itemIds: ["b", "c", "d"]))

        var played = ["a"]
        var session = 1
        var advances = 0
        while advances < 10 {
            let current = played.last!
            let playing = snapshot(session: "s\(session)", item: current, phase: .itemPlayback)
            let finished = snapshot(session: "s\(session)", item: current, phase: .finished)
            XCTAssertTrue(PlayQueueAdvance.shouldAdvance(from: playing, to: finished))
            // The same finish arriving again (a position tick) must not start a second item.
            XCTAssertFalse(PlayQueueAdvance.shouldAdvance(from: finished, to: finished))

            let store = PlayQueueStore(fileURL: fileURL) // a fresh store each hop: the app may have been reopened
            var queue = store.load()
            guard let next = queue.popNext(isAvailable: { library.contains($0) }) else { break }
            try store.save(queue)
            played.append(next)
            session += 1
            advances += 1
        }

        XCTAssertEqual(played, ["a", "b", "d"], "three items play in the order they were queued; the deleted one is skipped")
        XCTAssertTrue(PlayQueueStore(fileURL: fileURL).load().isEmpty, "the run leaves an empty queue and no file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: Queue screen rows (#1990)

    private func item(_ id: String, title: String? = nil, author: String? = nil, source: String? = nil) -> LibraryItemRow {
        LibraryItemRow(id: id, title: title ?? id, status: "ready", canDelete: true, sourceTitle: source, author: author)
    }

    func testRowsFollowQueueOrderNotLibraryOrder() {
        let queue = PlayQueue(itemIds: ["c", "a"])
        let rows = PlayQueueRows.rows(for: queue, items: [item("a"), item("b"), item("c")])
        XCTAssertEqual(rows.map(\.id), ["c", "a"])
    }

    func testADeletedItemHasNoRowAndNeitherJamsNorShifts() {
        let queue = PlayQueue(itemIds: ["gone", "a", "also-gone", "b"])
        let rows = PlayQueueRows.rows(for: queue, items: [item("a"), item("b")])
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
    }

    /// #3914: the playback screen's Next in queue looks at the head of the queue without taking it.
    func testPeekNextIsThePopNextAnswerWithoutTakingIt() {
        let queue = PlayQueue(itemIds: ["gone", "here", "later"])
        XCTAssertEqual(queue.peekNext { $0 != "gone" }, "here")
        XCTAssertEqual(queue.itemIds, ["gone", "here", "later"], "peeking takes nothing out")
        var popped = queue
        XCTAssertEqual(popped.popNext { $0 != "gone" }, queue.peekNext { $0 != "gone" })
        XCTAssertNil(PlayQueue().peekNext { _ in true })
        XCTAssertNil(PlayQueue(itemIds: ["gone"]).peekNext { _ in false })
    }

    /// #3914: Next in queue is offered only for an item that isn't the one playing or being started, and the same
    /// answer is what a tap is checked against, so a second tap or a tap at the queue's own advance starts nothing.
    func testNextToStartSkipsTheItemAlreadyPlayingOrStarting() {
        let all: (String) -> Bool = { _ in true }
        var queue = PlayQueue(itemIds: ["b", "c"])
        XCTAssertEqual(queue.nextToStart(playing: "a", starting: "a", isAvailable: all), "b")
        XCTAssertNil(queue.nextToStart(playing: "b", starting: "a", isAvailable: all), "the head is already playing")
        XCTAssertNil(queue.nextToStart(playing: "a", starting: "b", isAvailable: all), "the head is already being started")
        XCTAssertNil(PlayQueue().nextToStart(playing: "a", starting: "a", isAvailable: all), "an empty queue offers nothing")
        // After b has started it left the queue: a second tap, drawn for b, finds c and so does not match b.
        queue.remove("b")
        XCTAssertEqual(queue.nextToStart(playing: "b", starting: "b", isAvailable: all), "c")
        XCTAssertNotEqual(queue.nextToStart(playing: "b", starting: "b", isAvailable: all), "b")
    }

    func testPruneMakesTheQueueTheSameListAsTheRowsSoAReorderHitsTheRightItem() {
        var queue = PlayQueue(itemIds: ["gone", "a", "b", "c"])
        let items = [item("a"), item("b"), item("c")]
        queue.prune { id in items.contains { $0.id == id } }
        XCTAssertEqual(queue.itemIds, ["a", "b", "c"])
        // The screen's row 2 ("c") dragged to the top.
        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(queue.itemIds, ["c", "a", "b"])
    }

    func testSubtitleIsTheAuthorElseTheSourceElseNothing() {
        let queue = PlayQueue(itemIds: ["a", "b", "c", "d"])
        let rows = PlayQueueRows.rows(for: queue, items: [
            item("a", author: " Ada "),
            item("b", author: "  ", source: "Hakai"),
            item("c", source: "Hakai"),
            item("d"),
        ])
        XCTAssertEqual(rows.map(\.subtitle), ["Ada", "Hakai", "Hakai", nil])
    }

    func testTheCountAndNextLines() {
        XCTAssertEqual(PlayQueueRows.countLine(1), "1 waiting")
        XCTAssertEqual(PlayQueueRows.countLine(3), "3 waiting")
        let rows = PlayQueueRows.rows(for: PlayQueue(itemIds: ["a"]), items: [item("a", title: "How whales sleep")])
        XCTAssertEqual(PlayQueueRows.nextLine(rows), "Next: How whales sleep")
        XCTAssertNil(PlayQueueRows.nextLine([]))
    }
}
