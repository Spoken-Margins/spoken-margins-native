import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #4046 PR 1: follow lists are stored as their own record kind, over a real temporary SQLite file, without
/// changing the database the shipped builds open.
final class FollowListStoreTests: XCTestCase {
    func testListsAndMembersSurviveAReopenAndARenameKeepsTheId() throws {
        let path = temporaryDatabasePath()
        var news = FollowList(id: "news", name: "News", createdAt: date(1), members: [
            ListMember(feedKey: "https://a.example/feed"), ListMember(feedKey: "https://b.example/feed", podcastGUID: "guid-b"),
        ])
        let science = FollowList(id: "science", name: "Science", createdAt: date(2), members: [ListMember(feedKey: "https://b.example/feed")])
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveFollowList(news)
            try store.saveFollowList(science)
        }
        do {
            let store = try SQLiteSessionStore(path: path)
            XCTAssertEqual(try store.loadFollowLists(), [news, science])
            news.name = "Daily news"
            news.add(ListMember(feedKey: "https://c.example/feed"))
            try store.saveFollowList(news)
        }
        let store = try SQLiteSessionStore(path: path)
        let reopened = try store.loadFollowLists()
        XCTAssertEqual(reopened.map(\.id), ["news", "science"], "a rename keeps the id, so it stays one record")
        XCTAssertEqual(reopened.first?.name, "Daily news")
        XCTAssertEqual(reopened.first?.members.map(\.feedKey), ["https://a.example/feed", "https://b.example/feed", "https://c.example/feed"])
        XCTAssertEqual(try store.loadFollowList(id: "science"), science)
        XCTAssertNil(try store.loadFollowList(id: "missing"))
        try store.deleteFollowList(id: "news")
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadFollowLists().map(\.id), ["science"])
    }

    func testOneShowCanBeInTwoListsWithOneMemberRowEach() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let shared = ListMember(feedKey: "https://shared.example/feed")
        try store.saveFollowList(FollowList(id: "a", name: "A", createdAt: date(1), members: [shared, shared]))
        try store.saveFollowList(FollowList(id: "b", name: "B", createdAt: date(2), members: [shared]))
        let lists = try store.loadFollowLists()
        XCTAssertEqual(lists.map { $0.members.count }, [1, 1], "a repeat inside one list is one member")
        XCTAssertEqual(lists.filter { $0.contains(feedKey: shared.feedKey) }.map(\.id), ["a", "b"])
    }

    func testRemovingAShowFromEveryListLeavesTheListsAndOtherShows() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let gone = ListMember(feedKey: "https://gone.example/feed", podcastGUID: "guid-gone")
        let kept = ListMember(feedKey: "https://kept.example/feed")
        try store.saveFollowList(FollowList(id: "a", name: "A", createdAt: date(1), members: [gone, kept]))
        try store.saveFollowList(FollowList(id: "b", name: "B", createdAt: date(2), members: [gone]))
        try store.saveFollowList(FollowList(id: "c", name: "C", createdAt: date(3), members: [kept]))

        let changed = try store.removeFromFollowLists(feedKey: "https://gone.example/feed")
        XCTAssertEqual(changed.sorted(), ["a", "b"])
        let lists = try store.loadFollowLists()
        XCTAssertEqual(lists.map(\.id), ["a", "b", "c"], "an emptied list stays")
        XCTAssertEqual(lists.map { $0.members.map(\.feedKey) }, [["https://kept.example/feed"], [], ["https://kept.example/feed"]])
        XCTAssertEqual(try store.removeFromFollowLists(feedKey: "https://gone.example/feed"), [], "nothing left to remove")
    }

    func testDeletingAListNeverUnfollowsAShow() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let subscription = FeedSubscription(id: "sub", source: SourceIdentity(
            id: "src", kind: .podcastFeed, canonicalURL: "https://a.example/feed", host: "a.example"
        ), createdAt: date(0))
        try store.saveFeedSubscription(subscription)
        try store.saveFollowList(FollowList(id: "l", name: "L", createdAt: date(1), members: [ListMember(feedKey: "https://a.example/feed")]))
        try store.deleteFollowList(id: "l")
        XCTAssertEqual(try store.loadFeedSubscriptions(), [subscription])
    }

    func testListsLeaveTheSchemaAndTheBuild29ReadsUnchanged() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        let before = try store.listItems()
        for index in 0..<5 {
            try store.saveFollowList(FollowList(id: "l\(index)", name: "L\(index)", createdAt: date(Double(index)),
                                                members: [ListMember(feedKey: "https://a.example/feed")]))
        }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        let build29Schema = try Self.build29SchemaObjects()
        XCTAssertEqual(try Self.schemaObjects(atPath: path), build29Schema, "lists add no table, column or index")
        XCTAssertEqual(try store.listItems(), before)
        XCTAssertEqual(try SQLiteSessionStore(path: path).listItems(), before)
        XCTAssertEqual(try store.loadFeedSubscriptions(), [])
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testAListAnOlderBuildSetAsideIsRestoredOnOpen() throws {
        let path = temporaryDatabasePath()
        let list = FollowList(id: "l", name: "L", createdAt: date(1), members: [ListMember(feedKey: "https://a.example/feed")])
        try SQLiteSessionStore(path: path).saveFollowList(list)
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, 'older build could not decode this row', '2026-02-03 04:05:06' FROM records WHERE kind = 'follow_list';
            """, at: path)
        try StoreRawSQL.execute("DELETE FROM records WHERE kind = 'follow_list';", at: path)
        XCTAssertEqual(try SQLiteSessionStore(path: path).loadFollowLists(), [list])
        XCTAssertEqual(try SQLiteSessionStore(path: path).quarantinedRecordCount(), 0)
    }

    // MARK: Fixtures

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "follow-lists-\(UUID().uuidString).sqlite").path
    }

    private static func schemaObjects(atPath path: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "FollowListStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "FollowListStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        var objects: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            objects.append((0..<4).map { column in
                sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) } ?? ""
            }.joined(separator: " | "))
        }
        return objects
    }

    private static func build29SchemaObjects() throws -> [String] {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let copy = FileManager.default.temporaryDirectory.appending(path: "build29-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        return try schemaObjects(atPath: copy.path)
    }
}
