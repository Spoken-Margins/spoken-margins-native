import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4046 PR 6: list addresses are read only on a listener's action. The checker is called for exactly four triggers, and the
/// launch, background, follow and undo refreshes never reach the store or the network.
final class FollowedRefreshTriggerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000_000)

    override func setUp() {
        super.setUp()
        ListLinkStubProtocol.reset()
    }

    func testExactlyFourTriggersCheckListLinks() {
        let checking = Set(FollowedRefreshTrigger.allCases.filter(\.checksListLinks))
        XCTAssertEqual(checking, [.tabAppear, .pull, .refreshButton, .checkNow])
        let neverChecking = Set(FollowedRefreshTrigger.allCases).subtracting(checking)
        XCTAssertEqual(neverChecking, [.startup, .afterFollow, .undo, .background, .foreground, .localChange])
        XCTAssertTrue(FollowedRefreshTrigger.allCases.filter(\.forcesListLinkCheck).allSatisfy(\.checksListLinks), "a trigger that forces a check checks")
        XCTAssertEqual(Set(FollowedRefreshTrigger.allCases.filter(\.forcesListLinkCheck)), [.pull, .refreshButton, .checkNow])
    }

    func testOpeningFollowingReadsOnlyLinksNotReadInTheLastSixHours() {
        var link = ListLink(listId: "list", url: "https://a.example/l.opml", title: "A")
        XCTAssertTrue(ListLinkSchedule.isDue(link, trigger: .tabAppear, now: now), "never read")
        link.statusAt = now.addingTimeInterval(-ListLinkSchedule.staleAfter + 1)
        XCTAssertFalse(ListLinkSchedule.isDue(link, trigger: .tabAppear, now: now), "just under six hours")
        link.statusAt = now.addingTimeInterval(-ListLinkSchedule.staleAfter)
        XCTAssertTrue(ListLinkSchedule.isDue(link, trigger: .tabAppear, now: now), "six hours")
        link.statusAt = now.addingTimeInterval(3_600)
        XCTAssertTrue(ListLinkSchedule.isDue(link, trigger: .tabAppear, now: now), "a clock set back does not hold a link off")
        // A failed check is tried again sooner: opened offline, then online, must not wait six hours.
        link.status = .unreachable
        link.statusAt = now.addingTimeInterval(-ListLinkSchedule.retryAfterFailure + 1)
        XCTAssertFalse(ListLinkSchedule.isDue(link, trigger: .tabAppear, now: now), "just under 15 minutes after a failure")
        link.statusAt = now.addingTimeInterval(-ListLinkSchedule.retryAfterFailure)
        XCTAssertTrue(ListLinkSchedule.isDue(link, trigger: .tabAppear, now: now), "15 minutes after a failure")
        link.status = .ok
        link.statusAt = now
        for trigger in [FollowedRefreshTrigger.pull, .refreshButton, .checkNow] {
            XCTAssertTrue(ListLinkSchedule.isDue(link, trigger: trigger, now: now), "\(trigger) reads every link")
        }
        for trigger in FollowedRefreshTrigger.allCases where !trigger.checksListLinks {
            link.statusAt = nil
            XCTAssertFalse(ListLinkSchedule.isDue(link, trigger: trigger, now: now), "\(trigger) reads none")
        }
    }

    /// A store that records every question it is asked.
    private actor SpyStore: ListLinkStoring {
        var links: [ListLink]
        var lists: Set<String>
        private(set) var listLinksCalls = 0
        private(set) var saved: [ListLink] = []
        var onList: (@Sendable () async -> Void)?

        init(links: [ListLink], lists: Set<String> = ["list"]) {
            self.links = links
            self.lists = lists
        }

        func setOnList(_ hook: (@Sendable () async -> Void)?) { onList = hook }

        func listLinks() async throws -> [ListLink] {
            listLinksCalls += 1
            if let hook = onList { await hook() }
            return links
        }

        func existingListIDs() async throws -> Set<String> { lists }

        func saveChecked(_ link: ListLink) async throws {
            saved.append(link)
            if let index = links.firstIndex(where: { $0.id == link.id }) { links[index] = link }
        }
    }

    private func runner(_ store: SpyStore) -> ListLinkRunner {
        ListLinkRunner(store: store, checker: ListLinkChecker(session: ListLinkStubProtocol.session()), clock: { Date(timeIntervalSince1970: 5_000_000) })
    }

    private func staleLink(_ id: String, _ url: String) -> ListLink {
        ListLink(id: id, listId: "list", url: url, title: id, statusAt: Date(timeIntervalSince1970: 1_000))
    }

    func testTheRunnerTouchesNeitherTheStoreNorTheNetworkForTheOtherSixTriggers() async {
        let url = "https://trig.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1)))
        let store = SpyStore(links: [staleLink("a", url)])
        let runner = runner(store)
        for trigger in FollowedRefreshTrigger.allCases where !trigger.checksListLinks {
            let outcome = await runner.run(trigger: trigger)
            XCTAssertEqual(outcome, .notChecked, "\(trigger)")
        }
        let calls = await store.listLinksCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(ListLinkStubProtocol.requested, [], "the background pass never calls the list checker")
    }

    func testEachListenerActionReadsTheLinks() async {
        for trigger in [FollowedRefreshTrigger.tabAppear, .pull, .refreshButton, .checkNow] {
            ListLinkStubProtocol.reset()
            let url = "https://act-\(trigger.rawValue).example/l.opml"
            ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1)))
            let store = SpyStore(links: [staleLink("a", url)])
            let outcome = await runner(store).run(trigger: trigger)
            XCTAssertEqual(outcome, .finished(ListLinkRunner.Report(checkedLinkIDs: ["a"])), "\(trigger)")
            XCTAssertEqual(ListLinkStubProtocol.count(of: url), 1)
            let saved = await store.saved
            XCTAssertEqual(saved.first?.pending?.added.count, 1)
        }
    }

    func testOpeningFollowingSkipsALinkReadMinutesAgoAndAPullReadsIt() async {
        let url = "https://fresh.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml())
        var fresh = staleLink("a", url)
        fresh.statusAt = now.addingTimeInterval(-600)
        let store = SpyStore(links: [fresh])
        let runner = runner(store)
        let opened = await runner.run(trigger: .tabAppear)
        XCTAssertEqual(opened, .finished(ListLinkRunner.Report()))
        XCTAssertEqual(ListLinkStubProtocol.count(of: url), 0)
        _ = await runner.run(trigger: .pull)
        XCTAssertEqual(ListLinkStubProtocol.count(of: url), 1)
    }

    func testCheckNowReadsOnlyThatLinkAndASkippedListIsNeverRead() async {
        for id in ["a", "b", "orphan"] { ListLinkStubProtocol.serve("https://only.example/\(id).opml", text: ListLinkFixture.opml()) }
        var orphan = staleLink("orphan", "https://only.example/orphan.opml")
        orphan = ListLink(id: orphan.id, listId: "deleted-list", url: orphan.url, title: "Orphan")
        let store = SpyStore(links: [staleLink("a", "https://only.example/a.opml"), staleLink("b", "https://only.example/b.opml"), orphan])
        let runner = runner(store)
        _ = await runner.run(trigger: .checkNow, onlyLinkID: "b")
        XCTAssertEqual(ListLinkStubProtocol.requested, ["https://only.example/b.opml"])
        ListLinkStubProtocol.reset()
        ListLinkStubProtocol.serve("https://only.example/a.opml", text: ListLinkFixture.opml())
        ListLinkStubProtocol.serve("https://only.example/b.opml", text: ListLinkFixture.opml())
        _ = await runner.run(trigger: .pull)
        XCTAssertEqual(Set(ListLinkStubProtocol.requested), ["https://only.example/a.opml", "https://only.example/b.opml"], "a link whose list was deleted is not read")
    }

    func testATabAppearAndAPullAtOnceMakeOneProposalAndTheLaterRequestIsNotDropped() async {
        let url = "https://burst.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...2)))
        let store = SpyStore(links: [staleLink("a", url)])
        let runner = runner(store)
        // The tab-appear pass is held inside its first store read until the pull has asked.
        let gate = AsyncGate()
        await store.setOnList { await gate.wait() }
        let opened = Task { await runner.run(trigger: .tabAppear) }
        await gate.waitUntilWaiting()
        let pulled = await runner.run(trigger: .pull)
        XCTAssertEqual(pulled, .queued, "a request during a pass is queued, not run beside it")
        await store.setOnList(nil)
        await gate.open()
        let outcome = await opened.value
        guard case .finished(let report) = outcome else { return XCTFail("expected the first run to finish") }
        XCTAssertEqual(report.checkedLinkIDs, ["a", "a"], "the tab-appear pass, then the pull's own")
        let saved = await store.saved
        XCTAssertEqual(saved.last?.pending?.added.count, 2)
        XCTAssertEqual(saved.last?.pending, saved.first?.pending, "one proposal, rewritten the same")
    }

    func testRunWithoutWaitingReturnsAtOnceAndStillReadsTheLinkForAListenerActionOnly() async throws {
        let url = "https://nowait.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml(rows: ListLinkFixture.rows(1...1)))
        let store = SpyStore(links: [staleLink("a", url)])
        let runner = runner(store)
        runner.runWithoutWaiting(trigger: .background)
        runner.runWithoutWaiting(trigger: .startup)
        runner.runWithoutWaiting(trigger: .pull)
        // Wait on the state, with a deadline that is only a ceiling.
        let deadline = Date().addingTimeInterval(20)
        while await store.saved.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let saved = await store.saved
        XCTAssertEqual(saved.count, 1, "the pull read the link; the background and launch calls read nothing")
        XCTAssertEqual(ListLinkStubProtocol.count(of: url), 1)
    }

    func testARequestAPassAlreadyServesIsNotRunAgain() async {
        let url = "https://dupe.example/l.opml"
        ListLinkStubProtocol.serve(url, text: ListLinkFixture.opml())
        let store = SpyStore(links: [staleLink("a", url)])
        let runner = runner(store)
        let gate = AsyncGate()
        await store.setOnList { await gate.wait() }
        let first = Task { await runner.run(trigger: .pull) }
        await gate.waitUntilWaiting()
        let second = await runner.run(trigger: .refreshButton)
        XCTAssertEqual(second, .queued)
        await store.setOnList(nil)
        await gate.open()
        let outcome = await first.value
        guard case .finished(let report) = outcome else { return XCTFail("expected the first run to finish") }
        XCTAssertEqual(report.checkedLinkIDs, ["a"], "a pass that read every link serves the refresh button too")
    }
}

/// Holds one caller until the test lets it go; the test can wait until a caller is held.
private actor AsyncGate {
    private var opened = false
    private var held: CheckedContinuation<Void, Never>?
    private var watcher: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            held = continuation
            watcher?.resume()
            watcher = nil
        }
    }

    func waitUntilWaiting() async {
        if held != nil { return }
        await withCheckedContinuation { watcher = $0 }
    }

    func open() {
        opened = true
        held?.resume()
        held = nil
    }
}
