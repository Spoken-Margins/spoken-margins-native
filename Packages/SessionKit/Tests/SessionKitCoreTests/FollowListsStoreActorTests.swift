import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4046 PR 2: the off-main lists service the screens call, over a real temporary SQLite file, including a relaunch.
final class FollowListsStoreActorTests: XCTestCase {
    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "follow-lists-actor-\(UUID().uuidString).sqlite").path
    }

    private let feedA = ListMember(feedKey: "https://a.example/feed")
    private let feedB = ListMember(feedKey: "https://b.example/feed")
    private func date(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + n) }

    func testCreateTickRenameAndDeleteSurviveARelaunch() async throws {
        let path = temporaryDatabasePath()
        do {
            let service = FollowListsStore(store: try SQLiteSessionStore(path: path))
            let created = try await service.create(name: "News", adding: feedA, id: "news", now: date(1))
            XCTAssertNil(created.problem)
            XCTAssertEqual(created.changedListID, "news")
            XCTAssertEqual(created.lists.map(\.name), ["News"])
            XCTAssertEqual(created.lists.first?.members, [feedA], "the new list is ticked for the show it was made from")

            _ = try await service.create(name: "Commute", id: "commute", now: date(2))
            let ticked = try await service.setMembership(of: feedB, inList: "commute", isMember: true)
            XCTAssertEqual(ticked.first { $0.id == "commute" }?.members, [feedB])
            let renamed = try await service.rename(id: "news", to: "Daily news")
            XCTAssertEqual(renamed.changedListID, "news")
        }
        let service = FollowListsStore(store: try SQLiteSessionStore(path: path))
        let reopened = try await service.lists()
        XCTAssertEqual(reopened.map(\.id), ["news", "commute"])
        XCTAssertEqual(reopened.map(\.name), ["Daily news", "Commute"], "a rename keeps the id")
        let afterDelete = try await service.delete(id: "news")
        XCTAssertEqual(afterDelete.map(\.id), ["commute"])
        let again = try await FollowListsStore(store: try SQLiteSessionStore(path: path)).lists()
        XCTAssertEqual(again.map(\.id), ["commute"])
    }

    func testARefusedNameChangesNothingAndSaysWhy() async throws {
        let service = FollowListsStore(store: try SQLiteSessionStore(path: temporaryDatabasePath()))
        _ = try await service.create(name: "News", id: "news", now: date(1))
        let duplicate = try await service.create(name: " news ")
        XCTAssertEqual(duplicate.problem, .duplicate(existingName: "News"))
        XCTAssertNil(duplicate.changedListID)
        XCTAssertEqual(duplicate.lists.map(\.id), ["news"])
        let comma = try await service.rename(id: "news", to: "A, B")
        XCTAssertEqual(comma.problem, .containsCommaOrSlash)
        XCTAssertEqual(comma.lists.first?.name, "News")
        let gone = try await service.rename(id: "gone", to: "Fine")
        XCTAssertNil(gone.problem)
        XCTAssertNil(gone.changedListID)
    }

    func testTickingTwiceAndUntickingAreIdempotent() async throws {
        let service = FollowListsStore(store: try SQLiteSessionStore(path: temporaryDatabasePath()))
        _ = try await service.create(name: "News", id: "news", now: date(1))
        _ = try await service.setMembership(of: feedA, inList: "news", isMember: true)
        let twice = try await service.setMembership(of: feedA, inList: "news", isMember: true)
        XCTAssertEqual(twice.first?.members, [feedA], "one row per show")
        let removed = try await service.setMembership(of: feedA, inList: "news", isMember: false)
        XCTAssertEqual(removed.first?.members, [])
        let again = try await service.setMembership(of: feedA, inList: "news", isMember: false)
        XCTAssertEqual(again.first?.members, [])
        let missing = try await service.setMembership(of: feedA, inList: "gone", isMember: true)
        XCTAssertEqual(missing.map(\.id), ["news"], "a list deleted under the sheet is left alone")
    }

    func testUnfollowTakesTheShowOutOfEveryListAndUndoPutsItBack() async throws {
        let service = FollowListsStore(store: try SQLiteSessionStore(path: temporaryDatabasePath()))
        _ = try await service.create(name: "News", adding: feedA, id: "news", now: date(1))
        _ = try await service.create(name: "Commute", adding: feedA, id: "commute", now: date(2))
        _ = try await service.create(name: "Other", adding: feedB, id: "other", now: date(3))

        let left = try await service.removeFromAllLists(feedKey: feedA.feedKey)
        XCTAssertEqual(Set(left.leftIDs), ["news", "commute"])
        XCTAssertEqual(left.lists.map(\.id), ["news", "commute", "other"], "a list left empty stays")
        XCTAssertEqual(left.lists.first { $0.id == "other" }?.members, [feedB])
        XCTAssertTrue(left.lists.filter { $0.id != "other" }.allSatisfy { $0.members.isEmpty })

        let none = try await service.removeFromAllLists(feedKey: "https://nobody.example/feed")
        XCTAssertEqual(none.leftIDs, [])

        // Undo: back in the lists it was in, skipping one deleted since.
        _ = try await service.delete(id: "commute")
        let restored = try await service.restore(member: feedA, toLists: left.leftIDs)
        XCTAssertEqual(restored.first { $0.id == "news" }?.members, [feedA])
        XCTAssertNil(restored.first { $0.id == "commute" })
    }
}
