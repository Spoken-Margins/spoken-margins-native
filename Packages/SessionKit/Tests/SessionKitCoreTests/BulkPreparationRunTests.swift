import XCTest
@testable import SessionKit

/// #969: the "Prepare All Included" run's stale-work rule. Each item parks in a scripted host until the test
/// releases it, so the order "A invalidated, B started, A's late result lands" is exact. "Nothing happens" is shown
/// by waiting for a later run's events and then checking the log, never by sleeping.
@MainActor
final class BulkPreparationRunTests: XCTestCase {
    func testItemsRunOneAtATimeInOrderAndTheRunCompletesOnce() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b"], host: host)
        await host.waitForLog(count: 1)
        XCTAssertEqual(host.log, [.began("a")], "the second item waits for the first")
        XCTAssertTrue(run.hasTask)

        host.release("a")
        await host.waitForLog(count: 3)
        XCTAssertEqual(host.log, [.began("a"), .finishedOne(prepared: true), .began("b")])

        host.release("b", prepared: false)
        await host.waitForLog(count: 5)
        XCTAssertEqual(
            host.log,
            [.began("a"), .finishedOne(prepared: true), .began("b"), .finishedOne(prepared: false), .completed],
            "a fallback is still counted as finished, and completion is reported once"
        )
        XCTAssertFalse(run.hasTask, "a finished run drops its task")
        XCTAssertEqual(host.liveWhenReturned, ["a": true, "b": true])
    }

    func testAnEmptyRunCompletesAtOnce() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: [], host: host)
        await host.waitForLog(count: 1)
        XCTAssertEqual(host.log, [.completed])
        XCTAssertFalse(run.hasTask)
    }

    /// The Cancel button: A is invalidated mid-item, B starts, then A's late result lands. A's ticket is stale, so
    /// the host drops its work; nothing of A is counted, no further item of A starts, and B finishes on its own.
    func testAnInvalidatedRunsLateResultNeitherCountsNorStartsTheNextItem() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b"], host: host)
        await host.waitForLog(count: 1)

        run.invalidateAndCancel()
        XCTAssertFalse(run.hasTask, "Cancel drops the task at once")

        run.start(ids: ["z"], host: host)
        await host.waitForLog(count: 2)
        host.release("a")
        host.release("z")
        await host.waitForLog(count: 4)
        await host.waitForReturn(of: "a")

        XCTAssertEqual(
            host.log,
            [.began("a"), .began("z"), .finishedOne(prepared: true), .completed],
            "A's late result is not counted, \"b\" never starts, and only B completes"
        )
        XCTAssertEqual(host.liveWhenReturned["a"], false, "A's ticket was stale when its result landed")
        XCTAssertEqual(host.currentWhenReturned["a"], false)
        XCTAssertEqual(host.liveFromOtherTask["a"], false, "the counter alone turns A's ticket stale, even seen from a task that was not cancelled")
        XCTAssertEqual(host.liveWhenReturned["z"], true)
    }

    /// Cancel alone, with no run started after it, already turns the ticket stale for anything that is not the
    /// cancelled task itself (a result handed back through another task, a callback).
    func testCancelTurnsTheTicketStaleBeforeAnyLaterRunStarts() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a"], host: host)
        await host.waitForLog(count: 1)
        let before = run.generation

        run.invalidateAndCancel()
        host.release("a")
        await host.waitForReturn(of: "a")

        XCTAssertEqual(run.generation, before + 1)
        XCTAssertEqual(host.liveFromOtherTask["a"], false)
        XCTAssertEqual(host.currentWhenReturned["a"], false)
        XCTAssertEqual(host.log, [.began("a")], "a cancelled run reports nothing and does not complete")
    }

    /// Starting over a run that is going turns the old run's tickets stale the same way Cancel does.
    func testStartingOverARunningRunMakesTheOldTicketsStale() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b"], host: host)
        await host.waitForLog(count: 1)

        run.start(ids: ["z"], host: host)
        await host.waitForLog(count: 2)
        host.release("a")
        host.release("z")
        await host.waitForLog(count: 4)
        await host.waitForReturn(of: "a")

        XCTAssertEqual(host.log, [.began("a"), .began("z"), .finishedOne(prepared: true), .completed])
        XCTAssertEqual(host.liveWhenReturned["a"], false)
        XCTAssertEqual(host.currentWhenReturned["a"], false)
        XCTAssertEqual(host.liveFromOtherTask["a"], false)
    }

    /// The model's `deinit` is not on the main actor and bumps nothing: the ticket is no longer live (the item's result
    /// is dropped) but is still current, which is what bookkeeping that is right after a bare task cancel relies on.
    func testCancelOnlyFromOffTheMainActorStopsTheRunButLeavesTheCounter() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b"], host: host)
        await host.waitForLog(count: 1)
        let generationBefore = run.generation

        await Task.detached { run.cancelOnly() }.value
        XCTAssertEqual(run.generation, generationBefore, "cancelOnly never touches the counter")

        run.start(ids: ["z"], host: host)
        await host.waitForLog(count: 2)
        host.release("a")
        host.release("z")
        await host.waitForLog(count: 4)
        await host.waitForReturn(of: "a")

        XCTAssertEqual(host.log, [.began("a"), .began("z"), .finishedOne(prepared: true), .completed])
        XCTAssertEqual(host.liveWhenReturned["a"], false, "a cancelled task's result is dropped")
    }

    func testATicketIsCurrentButNotLiveWhenOnlyTheTaskWasCancelled() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a"], host: host)
        await host.waitForLog(count: 1)

        run.cancelOnly()
        host.release("a")
        await host.waitForReturn(of: "a")
        // The run's task ends without reporting anything; a second, empty run proves the moment has passed.
        run.start(ids: [], host: host)
        await host.waitForLog(count: 2)

        XCTAssertEqual(host.log, [.began("a"), .completed])
        XCTAssertEqual(host.liveWhenReturned["a"], false)
        XCTAssertEqual(host.currentWhenReturned["a"], true, "nothing replaced the run, so the counter still matched when it returned")
        XCTAssertEqual(host.liveFromOtherTask["a"], true, "a bare cancel touches no counter, so a task that was not cancelled still sees a live ticket")
    }

    // MARK: A queue that changes while the run goes (#4647)

    func testAnItemAppendedDuringARunGoesLastAndIsCountedOnce() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a"], host: host)
        await host.waitForLog(count: 1)
        XCTAssertEqual(host.pending, ["a"])

        XCTAssertTrue(run.append(id: "b"))
        XCTAssertTrue(run.append(id: "b"), "already queued: still true, not added twice")
        XCTAssertTrue(run.append(id: "a"), "in progress: not added again")
        XCTAssertEqual(host.log, [.began("a"), .appended("b")])
        XCTAssertEqual(host.pending, ["a", "b"])

        host.release("a")
        await host.waitForLog(count: 4)
        host.release("b")
        await host.waitForLog(count: 6)
        XCTAssertEqual(host.log, [.began("a"), .appended("b"), .finishedOne(prepared: true), .began("b"),
                                  .finishedOne(prepared: true), .completed])
        XCTAssertTrue(host.pending.isEmpty)
    }

    func testAppendWithNoLiveRunSaysSoAndAddsNothing() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        XCTAssertFalse(run.append(id: "a"), "no run yet")
        run.start(ids: [], host: host)
        await host.waitForLog(count: 1)
        XCTAssertFalse(run.append(id: "a"), "the run has ended")
        XCTAssertEqual(host.log, [.completed])
        XCTAssertTrue(run.pending.isEmpty)
    }

    func testAnItemSkippedBeforeItsTurnIsReportedSkippedAndNeverStarts() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b", "c"], host: host)
        await host.waitForLog(count: 1)

        XCTAssertTrue(run.skip(id: "b"))
        XCTAssertFalse(run.skip(id: "a"), "the item in progress is not skipped from outside")
        XCTAssertFalse(run.skip(id: "zzz"))
        XCTAssertEqual(host.pending, ["a", "c"])

        host.release("a")
        await host.waitForLog(count: 4)
        host.release("c")
        await host.waitForLog(count: 6)
        XCTAssertEqual(host.log, [.began("a"), .skipped, .finishedOne(prepared: true), .began("c"),
                                  .finishedOne(prepared: true), .completed])
    }

    func testARequeuedItemGoesToTheEndAndIsCountedOnlyWhenItFinishes() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b"], host: host)
        await host.waitForLog(count: 1)
        host.release("a", outcome: .requeued)
        await host.waitForLog(count: 2)
        XCTAssertEqual(host.log, [.began("a"), .began("b")], "nothing is reported for a requeued item")
        XCTAssertEqual(host.pending, ["a", "b"])
        host.release("b")
        await host.waitForLog(count: 4)
        host.release("a")
        await host.waitForLog(count: 6)
        XCTAssertEqual(host.log, [.began("a"), .began("b"), .finishedOne(prepared: true), .began("a"),
                                  .finishedOne(prepared: true), .completed])
    }

    func testCancelLeavesTheQueueEmpty() async {
        let host = ScriptedHost()
        let run = BulkPreparationRun()
        run.start(ids: ["a", "b"], host: host)
        await host.waitForLog(count: 1)
        run.append(id: "c")
        run.invalidateAndCancel()
        XCTAssertTrue(run.pending.isEmpty)
        XCTAssertTrue(host.pending.isEmpty)
        XCTAssertFalse(run.append(id: "d"), "a cancelled run takes nothing more")
        host.release("a")
        await host.waitForReturn(of: "a")
        XCTAssertEqual(host.log, [.began("a"), .appended("c")], "the late result neither counts nor starts b")
    }
}

@MainActor
private final class ScriptedHost: BulkPreparationHost {
    enum Event: Equatable {
        case began(String)
        case finishedOne(prepared: Bool)
        case skipped
        case appended(String)
        case completed
    }

    private(set) var log: [Event] = []
    private(set) var liveWhenReturned: [String: Bool] = [:]
    private(set) var currentWhenReturned: [String: Bool] = [:]
    /// What the ticket says from a task that was never cancelled: only the run counter can make this false.
    private(set) var liveFromOtherTask: [String: Bool] = [:]
    private var parked: [String: CheckedContinuation<BulkPreparationOutcome, Never>] = [:]
    /// The pending set the run last reported.
    private(set) var pending: Set<String> = []
    private var waiters: [(condition: () -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    func prepareForBulkRun(itemID: String, ticket: BulkPreparationTicket) async -> BulkPreparationOutcome {
        record(.began(itemID))
        let result = await withCheckedContinuation { parked[itemID] = $0 }
        liveWhenReturned[itemID] = ticket.isLive
        currentWhenReturned[itemID] = ticket.isCurrent
        liveFromOtherTask[itemID] = await Task { @MainActor in ticket.isLive }.value
        resumeSatisfiedWaiters()
        return result
    }

    func bulkRunDidFinishOne(_ outcome: BulkPreparationOutcome) {
        switch outcome {
        case .prepared: record(.finishedOne(prepared: true))
        case .fellBack: record(.finishedOne(prepared: false))
        case .skipped: record(.skipped)
        case .requeued: XCTFail("a requeued item is never reported")
        }
    }

    func bulkRunDidAppend(itemID: String) { record(.appended(itemID)) }

    func bulkRunPendingDidChange(_ pending: Set<String>) { self.pending = pending }

    func bulkRunDidComplete() { record(.completed) }

    /// Lets the parked item return. It does nothing for an item that is not parked.
    func release(_ id: String, prepared: Bool = true) {
        release(id, outcome: prepared ? .prepared : .fellBack)
    }

    func release(_ id: String, outcome: BulkPreparationOutcome) {
        parked.removeValue(forKey: id)?.resume(returning: outcome)
    }

    /// Returns once the log holds `count` events.
    func waitForLog(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("the log to hold \(count) events", file: file, line: line) { [self] in log.count >= count }
    }

    /// Returns once the item's result has come back to the host, so what the ticket said then is recorded.
    func waitForReturn(of id: String, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(id) to return", file: file, line: line) { [self] in liveFromOtherTask[id] != nil }
    }

    /// The deadline is only a ceiling for a run that never gets there; the failure names the log it stopped at.
    private func waitUntil(
        _ what: String,
        file: StaticString,
        line: UInt,
        _ condition: @escaping () -> Bool
    ) async {
        guard !condition() else { return }
        let ceiling = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !self.waiters.isEmpty else { return }
            XCTFail("waited for \(what); the log stopped at \(self.log)", file: file, line: line)
            let stuck = self.waiters
            self.waiters = []
            stuck.forEach { $0.continuation.resume() }
        }
        await withCheckedContinuation { waiters.append((condition, $0)) }
        ceiling.cancel()
    }

    private func record(_ event: Event) {
        log.append(event)
        resumeSatisfiedWaiters()
    }

    private func resumeSatisfiedWaiters() {
        var ready: [CheckedContinuation<Void, Never>] = []
        waiters.removeAll { waiter in
            guard waiter.condition() else { return false }
            ready.append(waiter.continuation)
            return true
        }
        ready.forEach { $0.resume() }
    }
}
