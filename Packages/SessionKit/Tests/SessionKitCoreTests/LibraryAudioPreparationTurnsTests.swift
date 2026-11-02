import XCTest
@testable import SessionKit

/// Codex audit on #380 (#534): the foreground loop and the background task each prepare one
/// part per turn, so they must stay on one item until its target is done.
final class LibraryAudioPreparationTurnsTests: XCTestCase {
    private let whileChargingPinned = AudioPreparationJob(
        id: "job-a", itemId: "a", manifestId: "m-a", policy: .whileCharging,
        requestedAt: Date(timeIntervalSince1970: 1), userPriority: 0
    )
    private let prepareNow = AudioPreparationJob(
        id: "job-b", itemId: "b", manifestId: "m-b", policy: .explicit,
        requestedAt: Date(timeIntervalSince1970: 2)
    )

    func testTheTwoPassesDoNotAlternateBetweenItems() {
        // A is pinned with "prepare next" (While Charging); B is a Prepare Now request.
        var turns = LibraryAudioPreparationTurns()
        let jobs = [whileChargingPinned, prepareNow]
        var prepared: [String] = []
        for _ in 0..<3 {
            for caller in [LibraryAudioPreparationCaller.background, .foreground] {
                if let job = turns.select(jobs, activeItemId: nil, for: caller) { prepared.append(job.itemId) }
            }
        }
        XCTAssertEqual(prepared, ["a", "a", "a"], "the foreground loop waits instead of starting B between A's parts")
        XCTAssertEqual(turns.preparingItemId, "a")
    }

    func testTheForegroundLoopSharesTheBackgroundTasksItemWhenItMayPrepareIt() {
        var turns = LibraryAudioPreparationTurns()
        let opening = AudioPreparationJob(
            id: "job-c", itemId: "c", manifestId: "m-c", policy: .demandWindow,
            requestedAt: Date(timeIntervalSince1970: 3), maximumChunkCount: 2
        )
        let jobs = [prepareNow, opening]
        XCTAssertEqual(turns.select(jobs, activeItemId: nil, for: .background)?.itemId, "c")
        XCTAssertEqual(turns.select(jobs, activeItemId: nil, for: .foreground)?.itemId, "c")
    }

    func testTheForegroundLoopPicksItsOwnWorkOnceTheBackgroundTaskStops() {
        // An explicit request must not starve while no background task is running.
        var turns = LibraryAudioPreparationTurns()
        let jobs = [whileChargingPinned, prepareNow]
        XCTAssertEqual(turns.select(jobs, activeItemId: nil, for: .background)?.itemId, "a")
        XCTAssertNil(turns.select(jobs, activeItemId: nil, for: .foreground))
        turns.stopped(.background)
        XCTAssertFalse(turns.backgroundIsPreparing)
        XCTAssertNil(turns.preparingItemId, "A stops showing progress when the background task stops")
        XCTAssertEqual(turns.select(jobs, activeItemId: nil, for: .foreground)?.itemId, "b")
        XCTAssertEqual(turns.preparingItemId, "b")
    }

    func testAWaitingForegroundLoopResumesOnceTheBackgroundTaskStops() {
        // Review on #380: the loop that stopped to wait must start again when the task ends,
        // even if the task ended before the loop finished stopping.
        var turns = LibraryAudioPreparationTurns()
        let jobs = [whileChargingPinned, prepareNow]
        _ = turns.select(jobs, activeItemId: nil, for: .background)
        XCTAssertNil(turns.select(jobs, activeItemId: nil, for: .foreground))
        XCTAssertFalse(turns.foregroundShouldRestart, "the background task is still preparing A")
        turns.stopped(.background)
        turns.stopped(.foreground)
        XCTAssertTrue(turns.foregroundShouldRestart)
        XCTAssertEqual(turns.select(jobs, activeItemId: nil, for: .foreground)?.itemId, "b")
        XCTAssertFalse(turns.foregroundShouldRestart, "no restart loop once it has its own work")
    }

    func testAForegroundPassBlockedByLowPowerOrHeatDoesNotRestartItself() {
        // #647: the loop waited for the background task, the task stopped, and the next pass was
        // refused by Low Power Mode or heat before it could select. The app restarts the loop
        // while foregroundShouldRestart holds, so a stale waiting flag made it spin.
        var turns = LibraryAudioPreparationTurns()
        let jobs = [whileChargingPinned, prepareNow]
        _ = turns.select(jobs, activeItemId: nil, for: .background)
        XCTAssertNil(turns.select(jobs, activeItemId: nil, for: .foreground))
        turns.stopped(.background)
        XCTAssertTrue(turns.foregroundShouldRestart)
        turns.blocked(.foreground) // the refused pass
        turns.stopped(.foreground) // the loop's finalizer
        XCTAssertFalse(turns.foregroundShouldRestart, "a refused pass settles instead of restarting")
        // Once Low Power Mode or heat clears, the next pass the app starts takes B.
        XCTAssertEqual(turns.select(jobs, activeItemId: nil, for: .foreground)?.itemId, "b")
        XCTAssertFalse(turns.foregroundShouldRestart)
    }

    func testABlockedForegroundPassWhileTheBackgroundTaskRunsLeavesItsItemShowing() {
        var turns = LibraryAudioPreparationTurns()
        _ = turns.select([whileChargingPinned, prepareNow], activeItemId: nil, for: .background)
        turns.blocked(.foreground)
        XCTAssertTrue(turns.backgroundIsPreparing)
        XCTAssertEqual(turns.preparingItemId, "a", "the background task's item keeps showing progress")
    }

    func testAResumedForegroundLoopThatCannotPrepareDoesNotRestartAgain() {
        // Codex audit on #644: the loop waits for a While Charging job, then Low Power Mode
        // stops the background task. The resumed pass exits at its power guard before it
        // selects, so the resume must be used up or the loop restarts itself forever.
        var turns = LibraryAudioPreparationTurns()
        let jobs = [whileChargingPinned, prepareNow]
        _ = turns.select(jobs, activeItemId: nil, for: .background)
        XCTAssertNil(turns.select(jobs, activeItemId: nil, for: .foreground))
        turns.stopped(.background)
        XCTAssertTrue(turns.foregroundLoopEnded(), "the waiting loop starts again once the task stops")
        // The replacement pass hits the Low Power Mode guard: it stops without selecting.
        turns.stopped(.foreground)
        XCTAssertFalse(turns.foregroundLoopEnded(), "a pass that never selected does not restart the loop again")
        XCTAssertFalse(turns.foregroundShouldRestart)
    }

    func testAForegroundLoopSharingTheBackgroundTasksItemFollowsANewHead() {
        var turns = LibraryAudioPreparationTurns()
        _ = turns.select([prepareNow], activeItemId: nil, for: .background)
        let playing = AudioPreparationJob(
            id: "job-p", itemId: "p", manifestId: "m-p", policy: .demandWindow,
            requestedAt: Date(timeIntervalSince1970: 0), maximumChunkCount: 2
        )
        XCTAssertEqual(turns.select([prepareNow, playing], activeItemId: "p", for: .foreground)?.itemId, "p")
        XCTAssertEqual(turns.preparingItemId, "p", "the row that shows progress is the one being prepared")
    }

    func testTheForegroundLoopNeverPreparesWhileChargingWork() {
        var turns = LibraryAudioPreparationTurns()
        XCTAssertNil(turns.select([whileChargingPinned], activeItemId: nil, for: .foreground))
        XCTAssertNil(turns.preparingItemId)
    }

    func testTheItemStopsShowingProgressWhenItsPassStops() {
        // The foreground loop was cancelled between parts (the listener started another item).
        var turns = LibraryAudioPreparationTurns()
        XCTAssertEqual(turns.select([prepareNow], activeItemId: nil, for: .foreground)?.itemId, "b")
        turns.stopped(.foreground)
        XCTAssertNil(turns.preparingItemId)
    }

    func testTheForegroundLoopStoppingKeepsTheBackgroundTasksItem() {
        var turns = LibraryAudioPreparationTurns()
        _ = turns.select([whileChargingPinned, prepareNow], activeItemId: nil, for: .background)
        turns.stopped(.foreground)
        XCTAssertEqual(turns.preparingItemId, "a", "the background task is still preparing A")
        turns.stopped(.background)
        XCTAssertNil(turns.preparingItemId)
    }

    func testABackgroundTaskEndingDoesNotClearTheForegroundLoopsItem() {
        var turns = LibraryAudioPreparationTurns()
        _ = turns.select([prepareNow], activeItemId: nil, for: .foreground)
        turns.stopped(.background) // a drain that did only episode maps
        XCTAssertEqual(turns.preparingItemId, "b")
    }

    func testThePlayingItemPreemptsBothPasses() {
        var turns = LibraryAudioPreparationTurns()
        let playing = AudioPreparationJob(
            id: "job-p", itemId: "p", manifestId: "m-p", policy: .demandWindow,
            requestedAt: Date(timeIntervalSince1970: 0), maximumChunkCount: 2
        )
        let jobs = [prepareNow, playing]
        XCTAssertEqual(turns.select(jobs, activeItemId: "p", for: .background)?.itemId, "p")
        XCTAssertEqual(turns.select(jobs, activeItemId: "p", for: .foreground)?.itemId, "p")
    }

    func testCancelledJobsAreIgnored() {
        var turns = LibraryAudioPreparationTurns()
        var cancelled = prepareNow
        cancelled.isCancelled = true
        XCTAssertNil(turns.select([cancelled], activeItemId: nil, for: .background))
        XCTAssertFalse(turns.backgroundIsPreparing)
        XCTAssertTrue(LibraryAudioPreparationTurns.eligible([cancelled], for: .background).isEmpty)
        XCTAssertEqual(LibraryAudioPreparationTurns.eligible([whileChargingPinned, prepareNow], for: .foreground).map(\.id), ["job-b"])
    }
}
