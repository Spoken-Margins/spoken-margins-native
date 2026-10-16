import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #477: Dismiss in Following can be undone. Undo restores the entry's previous state through the
/// existing entry-state path, so the Build 29 database is untouched.
final class FollowingDismissUndoTests: XCTestCase {
    private func makeCoordinator(entries: [FeedEntry]) throws -> FollowedSourceCoordinator {
        let repository = InMemorySessionRepository()
        try repository.saveFeedSubscription(FeedSubscription(
            id: "subscription",
            source: SourceIdentity(id: "source", kind: .podcastFeed, canonicalURL: "https://publisher.example/feed", host: "publisher.example", title: "Publisher"),
            lastRefreshAt: Date()
        ))
        for entry in entries { try repository.saveFeedEntry(entry) }
        return FollowedSourceCoordinator(repository: repository, signals: nil)
    }

    private func entry(_ id: String, state: FeedEntryState = .unseen) -> FeedEntry {
        FeedEntry(id: id, subscriptionId: "subscription", canonicalURL: "https://publisher.example/\(id)", title: "Entry \(id)", publishedAt: Date(timeIntervalSince1970: 1_790_000_000), state: state)
    }

    func testUndoPutsADismissedEntryBackInTheInbox() async throws {
        let coordinator = try makeCoordinator(entries: [entry("a"), entry("b")])

        let previous = try await coordinator.dismissEntry(id: "a")
        XCTAssertEqual(previous, .unseen)
        var listed = try await coordinator.entries().map(\.id)
        XCTAssertEqual(listed, ["b"], "a dismissed entry leaves the inbox")

        try await coordinator.undoDismissEntry(id: "a", restoring: try XCTUnwrap(previous))
        listed = try await coordinator.entries().map(\.id).sorted()
        XCTAssertEqual(listed, ["a", "b"], "Undo lists the entry again")
    }

    func testUndoRestoresTheStateTheEntryHad() async throws {
        let coordinator = try makeCoordinator(entries: [entry("seen", state: .seen)])
        let previous = try await coordinator.dismissEntry(id: "seen")
        XCTAssertEqual(previous, .seen)
        try await coordinator.undoDismissEntry(id: "seen", restoring: .seen)
        let restored = try await coordinator.entries().first
        XCTAssertEqual(restored?.state, .seen)
    }

    /// Neighbours of the happy path: nothing to undo, or the entry moved on while the banner showed.
    func testDismissAndUndoLeaveOtherEntriesAndStatesAlone() async throws {
        let coordinator = try makeCoordinator(entries: [entry("a"), entry("imported", state: .imported)])

        let unknown = try await coordinator.dismissEntry(id: "missing")
        XCTAssertNil(unknown, "an entry that isn't there has nothing to undo")

        let first = try await coordinator.dismissEntry(id: "a")
        let second = try await coordinator.dismissEntry(id: "a")
        XCTAssertEqual(first, .unseen)
        XCTAssertNil(second, "dismissing again must not overwrite the state Undo would restore")

        // Undo on an entry that is no longer dismissed (added from elsewhere) changes nothing.
        try await coordinator.undoDismissEntry(id: "imported", restoring: .unseen)
        let listedAfterNoOp = try await coordinator.entries().map(\.id)
        XCTAssertEqual(listedAfterNoOp, [], "an imported entry stays out of the inbox; a stays dismissed")
    }
}
