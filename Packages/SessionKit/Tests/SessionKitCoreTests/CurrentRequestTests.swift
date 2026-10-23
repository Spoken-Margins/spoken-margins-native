import SessionKit
import XCTest

final class CurrentRequestTests: XCTestCase {
    func testANewerRequestMakesTheOlderTokenStale() {
        var slot = CurrentRequest()
        let first = slot.begin()
        XCTAssertTrue(slot.isCurrent(first))
        let second = slot.begin()
        XCTAssertFalse(slot.isCurrent(first))
        XCTAssertTrue(slot.isCurrent(second))
        XCTAssertFalse(slot.finish(first), "a superseded completion is dropped")
        XCTAssertTrue(slot.finish(second))
    }

    func testCancelMakesTheOutstandingTokenStale() {
        var slot = CurrentRequest()
        let token = slot.begin()
        slot.cancel()
        XCTAssertFalse(slot.isPending)
        XCTAssertFalse(slot.isCurrent(token))
        XCTAssertFalse(slot.finish(token), "a grant after Cancel acts on nothing")
    }

    func testAFinishedTokenActsOnce() {
        var slot = CurrentRequest()
        let token = slot.begin()
        XCTAssertTrue(slot.finish(token))
        XCTAssertFalse(slot.isPending)
        XCTAssertFalse(slot.finish(token), "the same completion can't act twice")
    }

    func testTokensFromAnEarlierCancelledRoundStayStale() {
        var slot = CurrentRequest()
        let old = slot.begin()
        slot.cancel()
        let fresh = slot.begin()
        XCTAssertFalse(slot.isCurrent(old))
        XCTAssertTrue(slot.isCurrent(fresh))
    }

    /// #2124: Play now on A starts a slow fetch; the listener starts B before it lands. A's completion
    /// must see that it is no longer current, and B's must still act.
    @MainActor
    func testADelayedFetchThatLandsAfterANewerRequestIsDropped() async {
        let model = PlayIntentModel()
        let gate = AsyncGate()

        let fetchA = model.playNow("A") { await gate.wait() }
        await gate.waitUntilWaiting()

        model.start("B") // the listener starts B while A is still fetching

        await gate.open()
        await fetchA.value
        XCTAssertEqual(model.started, ["B"], "A's late fetch must not act after B started")
    }

    @MainActor
    func testADelayedFetchWithNoNewerRequestStillActs() async {
        let model = PlayIntentModel()
        let gate = AsyncGate()
        let fetch = model.playNow("A") { await gate.wait() }
        await gate.waitUntilWaiting()
        await gate.open()
        await fetch.value
        XCTAssertEqual(model.started, ["A"])
    }
}

/// The app's Play-now shape in miniature: a tap begins a request, a slow fetch runs, and the completion
/// starts the item only if no newer request came in.
@MainActor
private final class PlayIntentModel {
    var intent = CurrentRequest()
    var started: [String] = []

    func playNow(_ item: String, fetch: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let token = intent.begin()
        return Task { @MainActor in
            await fetch()
            guard self.intent.finish(token) else { return }
            self.started.append(item)
        }
    }

    func start(_ item: String) {
        intent.cancel()
        started.append(item)
    }
}

/// Holds an async fetch until the test opens it.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilWaiting() async {
        while waiters.isEmpty && !isOpen { await Task.yield() }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
