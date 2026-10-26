import XCTest
@testable import SessionKit

/// #995: the foreground preparation loop's generation guard and its two ways to stop. Each run parks in a
/// scripted host until the test lets it return, so the order "A invalidated, B started, A exiting" is exact.
@MainActor
final class LibraryAudioPreparationLoopTests: XCTestCase {
    func testAStartWhileARunIsGoingRequestsContinuedProcessingButStartsNoSecondRun() async {
        let host = ScriptedHost()
        let loop = LibraryAudioPreparationLoop()
        loop.start(host: host)
        loop.start(host: host)
        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        await pause()
        XCTAssertEqual(host.runsStarted, 1, "one run, however often it is asked for")
        XCTAssertEqual(host.continuedRequests, 3, "every ask reaches continued processing, even with a run going (#905)")
        XCTAssertEqual(loop.generation, 1)
        XCTAssertTrue(loop.isRunning)

        host.finishRun(0)
        await settle { host.loopsEnded == 1 }
        XCTAssertFalse(loop.isRunning)
        XCTAssertEqual(host.runsStarted, 1, "a run that was not cancelled and has no resume ends for good")
    }

    /// A is invalidated, B starts, then A exits. A is stale: it must neither end B's run nor touch B's turn.
    func testAnInvalidatedRunCannotFinalizeTheRunThatReplacedIt() async {
        let host = ScriptedHost()
        let loop = LibraryAudioPreparationLoop()
        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        loop.stopAndInvalidate()
        XCTAssertFalse(loop.isRunning, "invalidating drops the task at once")
        loop.start(host: host)
        await settle { host.runsStarted == 2 }
        loop.turns.preparingItemId = "item-b"

        host.finishRun(0) // A exits while B is running
        await pause()
        XCTAssertEqual(host.loopsEnded, 0, "A's finalizer did not run")
        XCTAssertTrue(loop.isRunning, "B's task is still B's")
        XCTAssertEqual(loop.turns.preparingItemId, "item-b", "A did not stop B's item")
        XCTAssertEqual(host.runsStarted, 2, "A started nothing")
        XCTAssertEqual(loop.generation, 3, "start, invalidate, start")

        host.finishRun(1)
        await settle { host.loopsEnded == 1 }
        XCTAssertFalse(loop.isRunning)
        XCTAssertNil(loop.turns.preparingItemId, "B's own finalizer stops its turn")
    }

    /// A stale run with no replacement only stops its own turn: it must not restart a loop that was stopped on purpose.
    func testAnInvalidatedRunWithNoReplacementOnlyStopsItsTurn() async {
        let host = ScriptedHost()
        let loop = LibraryAudioPreparationLoop()
        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        loop.turns.preparingItemId = "item-a"
        loop.stopAndInvalidate()

        host.finishRun(0)
        await settle { host.loopsEnded == 1 }
        XCTAssertNil(loop.turns.preparingItemId, "its item stops showing progress (#281)")
        XCTAssertFalse(loop.isRunning)
        XCTAssertEqual(host.runsStarted, 1, "playback allows preparation, yet a stopped loop stays stopped")
    }

    /// #2694: the card is requested only for a run that can render.
    func testAStartRefusedByPlaybackRequestsNoContinuedCardAndStartsNoRun() async {
        let host = ScriptedHost()
        host.playbackAllows = false
        let loop = LibraryAudioPreparationLoop()
        loop.start(host: host)
        await pause()
        XCTAssertEqual(host.continuedRequests, 0)
        XCTAssertEqual(host.runsStarted, 0)
        XCTAssertFalse(loop.isRunning)

        host.playbackAllows = true // the listener tapped Make available offline
        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        XCTAssertEqual(host.continuedRequests, 1)
    }

    func testACancelOnlyRunEndsAndRestartsWhenPlaybackAllowsIt() async {
        let host = ScriptedHost()
        let loop = LibraryAudioPreparationLoop()
        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        loop.cancelOnly()
        XCTAssertTrue(loop.isRunning, "cancel-only leaves the task for the run's own finalizer")
        XCTAssertEqual(loop.generation, 1, "and does not invalidate the run")

        host.finishRun(0)
        await settle { host.runsStarted == 2 }
        XCTAssertEqual(host.loopsEnded, 1)
        XCTAssertEqual(host.continuedRequests, 2, "the restart goes through start, which asks for continued processing")
        XCTAssertEqual(loop.generation, 2)
        XCTAssertTrue(loop.isRunning)

        host.finishRun(1)
        await settle { host.loopsEnded == 2 }
        XCTAssertFalse(loop.isRunning, "the replacement run was not cancelled, so it ends")
        XCTAssertEqual(host.runsStarted, 2)
    }

    func testACancelOnlyRunDoesNotRestartWhileLivePlaybackHoldsTheRenderer() async {
        let host = ScriptedHost()
        let loop = LibraryAudioPreparationLoop()
        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        loop.cancelOnly()
        host.playbackAllows = false // read when the run ends, not when the loop was created

        host.finishRun(0)
        await settle { host.loopsEnded == 1 }
        XCTAssertFalse(loop.isRunning)
        XCTAssertEqual(host.runsStarted, 1)
    }

    /// The foreground loop stopped to wait for the background task, which has since stopped: the loop restarts once.
    func testABackgroundHandOffRestartsTheLoopOnce() async {
        let host = ScriptedHost()
        let loop = LibraryAudioPreparationLoop()
        let chargingOnly = AudioPreparationJob(id: "job-a", itemId: "a", manifestId: "manifest-a", policy: .whileCharging)
        _ = loop.turns.select([chargingOnly], activeItemId: nil, for: .background)
        XCTAssertNil(loop.turns.select([chargingOnly], activeItemId: nil, for: .foreground), "the loop waits for the background task")
        loop.turns.stopped(.background)
        XCTAssertTrue(loop.turns.foregroundShouldResume)

        loop.start(host: host)
        await settle { host.runsStarted == 1 }
        host.finishRun(0)
        await settle { host.runsStarted == 2 }
        XCTAssertFalse(loop.turns.foregroundShouldResume, "the resume is used up by the restart")

        host.finishRun(1)
        await settle { host.loopsEnded == 2 }
        XCTAssertFalse(loop.isRunning)
        XCTAssertEqual(host.runsStarted, 2, "one resume, not a restart loop")
    }

    func testTheLoopLetsGoOfItsHostWhenIdle() async {
        let loop = LibraryAudioPreparationLoop()
        weak var weakHost: ScriptedHost?
        do {
            let host = ScriptedHost()
            weakHost = host
            loop.start(host: host)
            await settle { host.runsStarted == 1 }
            host.finishRun(0)
            await settle { host.loopsEnded == 1 }
        }
        await pause()
        XCTAssertNil(weakHost, "no idle cycle: the loop holds its host only while a run is going")
    }

    // MARK: Helpers

    private func settle(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("the loop did not reach the expected state", file: file, line: line)
    }

    /// Long enough for a run that was just released to reach its finalizer.
    private func pause() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}

/// Runs park until `finishRun` returns them, in the order they started.
@MainActor
private final class ScriptedHost: LibraryAudioPreparationHost {
    var playbackAllows = true
    private(set) var continuedRequests = 0
    private(set) var runsStarted = 0
    private(set) var loopsEnded = 0
    private var parked: [Int: CheckedContinuation<Void, Never>] = [:]

    var playbackAllowsLibraryAudioPreparation: Bool { playbackAllows }

    func requestContinuedAudioPreparationIfNeeded() { continuedRequests += 1 }

    func runForegroundAudioPreparationPasses() async {
        let number = runsStarted
        runsStarted += 1
        await withCheckedContinuation { parked[number] = $0 }
    }

    func foregroundAudioPreparationLoopDidEnd() { loopsEnded += 1 }

    func finishRun(_ number: Int) {
        parked.removeValue(forKey: number)?.resume()
    }
}
