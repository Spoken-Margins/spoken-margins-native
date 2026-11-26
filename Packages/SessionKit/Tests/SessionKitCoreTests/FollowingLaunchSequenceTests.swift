import Foundation
import XCTest
@testable import SessionKit

/// The Following tab shows its saved items before the storage audit or any feed fetch has finished (#4387), and the feed
/// refresh doesn't wait for the audit (#4388).
final class FollowingLaunchSequenceTests: XCTestCase {
    /// Records the order things happened in, and holds a step open until the test lets it go.
    private actor Journal {
        private(set) var events: [String] = []
        private var gates: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []

        func note(_ event: String) { events.append(event) }

        func hold(_ name: String) async {
            if released.contains(name) { return }
            await withCheckedContinuation { gates[name] = $0 }
        }

        func release(_ name: String) {
            released.insert(name)
            gates.removeValue(forKey: name)?.resume()
        }

        func waitFor(_ event: String, timeout: TimeInterval = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if events.contains(event) { return true }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return false
        }
    }

    private func start(_ journal: Journal) -> Task<Void, Never> {
        Task {
            await FollowingLaunchSequence.run(
                publishSaved: { await journal.note("published") },
                audit: { await journal.note("audit started"); await journal.hold("audit"); await journal.note("audit finished") },
                refresh: { await journal.note("refresh started"); await journal.hold("fetch"); await journal.note("refresh finished") }
            )
        }
    }

    /// Fails without the fix: the old chain published only after the audit and the fetch.
    func testSavedItemsPublishWhileTheAuditAndTheFetchAreStalled() async {
        let journal = Journal()
        let launch = start(journal)

        let published = await journal.waitFor("published")
        let eventsAtPublish = await journal.events
        await journal.release("audit")
        await journal.release("fetch")
        await launch.value

        XCTAssertTrue(published, "saved items must publish with the audit still running")
        XCTAssertFalse(eventsAtPublish.contains("audit finished"))
        XCTAssertFalse(eventsAtPublish.contains("refresh finished"))
    }

    /// Fails without the fix: the refresh used to start only after the audit had finished (#4388).
    func testTheFeedRefreshStartsWhileTheStorageAuditIsStalled() async {
        let journal = Journal()
        let launch = start(journal)

        let refreshStarted = await journal.waitFor("refresh started")
        let eventsAtRefresh = await journal.events
        await journal.release("audit")
        await journal.release("fetch")
        await launch.value

        XCTAssertTrue(refreshStarted, "the refresh must start with the audit still running")
        XCTAssertTrue(eventsAtRefresh.contains("audit started"))
        XCTAssertFalse(eventsAtRefresh.contains("audit finished"))
    }

    func testTheRefreshStartsOnlyAfterTheSavedItemsPublished() async {
        let journal = Journal()
        let launch = start(journal)

        await journal.release("audit")
        await journal.release("fetch")
        await launch.value

        let events = await journal.events
        XCTAssertEqual(events.firstIndex(of: "refresh started").map { $0 > events.firstIndex(of: "published")! }, true)
    }

    func testTheLaunchReturnsOnlyWhenTheAuditAndTheRefreshHaveBothFinished() async {
        let journal = Journal()
        let launch = start(journal)

        _ = await journal.waitFor("refresh started")
        await journal.release("fetch")
        _ = await journal.waitFor("refresh finished")
        await journal.release("audit")
        await launch.value

        let events = await journal.events
        XCTAssertTrue(events.contains("audit finished"))
        XCTAssertTrue(events.contains("refresh finished"))
    }
}
